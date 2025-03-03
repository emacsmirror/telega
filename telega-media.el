;;; telega-media.el --- Media support for telega  -*- lexical-binding:t -*-

;; Copyright (C) 2018-2019 by Zajcev Evgeny.

;; Author: Zajcev Evgeny <zevlg@yandex.ru>
;; Created: Tue Jul 10 15:20:09 2018
;; Keywords:

;; telega is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; telega is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with telega.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Code to work with media in telega:
;;  - Download/upload files to cloud
;;  - Thumbnails
;;  - Stickers
;;  - Animations
;;  - Web pages
;;  etc

;;; Code:
(require 'telega-core)
(require 'telega-tdlib)

(declare-function telega-root-view--update "telega-root" (on-update-prop &rest args))
(declare-function telega-chat-title "telega-chat" (chat &optional no-badges))

(declare-function telega-msg-redisplay "telega-msg" (msg))

(declare-function telega-image-view-file "telega-modes" (tl-file &optional for-msg))


;;; Files downloading/uploading
(defun telega-file--ensure (file)
  "Ensure FILE is in `telega--files'.
Return FILE.
As side-effect might update root view, if current root view is \"Files\"."
  (when telega-debug
    (cl-assert file))
  (plist-put file :telega-file-recency (telega-time-seconds))
  (puthash (plist-get file :id) file telega--files)

  (telega-root-view--update :on-file-update file)
  file)

(defun telega-file-get (file-id &optional locally)
  "Return file associated with FILE-ID."
  (or (gethash file-id telega--files)
      (unless locally
        (telega-file--ensure (telega--getFile file-id)))))

(defun telega-file--renew (place prop)
  "Renew file value at PLACE and PROP."
  (when-let* ((ppfile (plist-get place prop))
              (file-id (plist-get ppfile :id))
              (file (or (gethash file-id telega--files)
                        (telega-file--ensure ppfile))))
    (plist-put place prop file)
    file))

(defun telega-file--add-update-callback (file-id update-callback)
  "Ensure FILE-ID is monitored with UPDATE-CALLBACK."
  (declare (indent 1))
  (cl-assert update-callback)
  (let ((cb-list (gethash file-id telega--files-updates)))
    (unless (memq update-callback cb-list)
      (puthash file-id (cons update-callback cb-list)
               telega--files-updates))))

(defun telega-file--del-update-callback (file-id update-callback)
  "Delete UPDATE-CALLBACK from callbacks for FILE-ID callbacks."
  (declare (indent 1))
  (cl-assert update-callback)
  (let ((left-cbs (delq update-callback
                        (gethash file-id telega--files-updates))))
    (if left-cbs
        (puthash file-id left-cbs telega--files-updates)
      (remhash file-id telega--files-updates))
    (telega-debug "%s %d: del CB, left callbacks %d"
                  (propertize "FILE-UPDATE" 'face 'bold)
                  file-id (length left-cbs))))

(defun telega-file--update (file &optional omit-throttle-p)
  "FILE has been updated, call any pending callbacks."
  (let* ((file-id (plist-get file :id))
         (old-file (gethash file-id telega--files))
         (throttle-p
          ;; NOTE: Throttle number of update callbacks calls
          ;; Throttle only if `:downloaded_size'/`:uploaded_size'
          ;; property advances more then 1/100s part of the file size
          ;; See https://github.com/zevlg/telega.el/issues/164
          (and (not omit-throttle-p)
               (or (and (telega-file--uploading-p file)
                        (telega-file--uploading-p old-file)
                        (< (- (telega-file--uploading-progress file)
                              (telega-file--uploading-progress old-file))
                           0.01))
                   (and (telega-file--downloading-p file)
                        (telega-file--downloading-p old-file)
                        (< (- (telega-file--downloading-progress file)
                              (telega-file--downloading-progress old-file))
                           0.01))))))
    (unless throttle-p
      (telega-file--ensure file)

      (let* ((callbacks (gethash file-id telega--files-updates))
             (left-cbs (cl-loop for cb in callbacks
                                when (funcall cb file)
                                collect cb)))
        (telega-debug "%s %S started with %d callbacks, left %d callbacks%s"
                      (propertize "FILE-UPDATE" 'face 'bold)
                      file-id (length callbacks) (length left-cbs)
                      (if omit-throttle-p " (forced)" ""))
        (if left-cbs
            (puthash file-id left-cbs telega--files-updates)
          (remhash file-id telega--files-updates))

        (when (and (not (telega-file--downloaded-p old-file))
                   (telega-file--downloaded-p file))
          (run-hook-with-args 'telega-file-downloaded-hook file))
        ))))

(cl-defun telega-file--download (file &key priority offset limit
                                      update-callback)
  "Download file denoted by FILE-ID.
PRIORITY - (1-32) the higher the PRIORITY, the earlier the file
will be downloaded. (default=1)
Run UPDATE-CALLBACK every time FILE gets updated.
To cancel downloading use `telega--cancelDownloadFile', it will
remove the UPDATE-CALLBACK as well.
OFFSET and LIMIT specifies file part to download."
  (declare (indent 1))
  ;; - If file already downloaded, then just call the callback
  ;; - If file already downloading, then just install the callback
  ;; - If file can be downloaded, then start downloading file and
  ;;   install callback after file started downloading
  (let* ((file-id (plist-get file :id))
         (dfile (or (telega-file-get file-id 'locally) file)))
    (cond ((telega-file--downloaded-p dfile)
           (when update-callback
             (funcall update-callback dfile)))

          ((telega-file--downloading-p dfile)
           (when update-callback
             (telega-file--add-update-callback file-id
               (lambda (file)
                 (funcall update-callback file)
                 (telega-file--downloading-p file)))))

          ((telega-file--can-download-p dfile)
           ;; NOTE: There might be pending updateFile event after
           ;; calling `telega--cancelDownloadFile', and it will remove
           ;; our newly installed callback, so we install it
           ;; permanently (by returning t) and remove after
           ;; `telega--downloadFile' completes
           (let ((cb (when update-callback
                       (lambda (file)
                         (funcall update-callback file)
                         t))))
             (when cb
               (telega-file--add-update-callback file-id cb))

             (telega--downloadFile file-id
               :priority priority
               :offset offset
               :limit limit
               :sync-p t
               :callback
               (when cb
                 (lambda (file-or-error)
                   (unless (telega--tl-error-p file-or-error)
                     (telega-file--update file-or-error 'force))
                   (telega-file--del-update-callback file-id cb)))))))))

;; NOTE: `telega--downloadFile' downloads data in pretty random order
;; Use `telega-file--split-to-parts' to split file to parts for
;; sequentual downloading.
(defun telega-file--split-to-parts (file chunk-size)
  "Split FILE by CHUNK-SIZE and return parts list."
  (let ((size (telega-file--size file))
        (parts nil))
    (while (> size 0)
      (setq size (- size chunk-size))
      (when (< size 0)
        (setq chunk-size (+ chunk-size size)
              size 0))
      (setq parts (cons (cons size chunk-size) parts)))
    parts))

(cl-defun telega-file--upload (filename &key file-type priority
                                        update-callback)
  "Upload FILENAME to the cloud.
Return file object, obtained from `telega--preliminaryUploadFile'."
  (declare (indent 1))
  (let ((ufile (telega--preliminaryUploadFile (expand-file-name filename)
                 :file-type file-type
                 :priority priority)))
    (if (telega-file--uploaded-p ufile)
        (when update-callback
          (funcall update-callback ufile))

      (when update-callback
        (telega-file--add-update-callback (plist-get ufile :id)
          (lambda (file)
            (funcall update-callback file)
            (telega-file--uploading-p file))))
      ufile)))


;;; Photos
(defmacro telega-thumbnail--get (type thumbnails)
  "Get thumbnail of TYPE from list of THUMBNAILS.
Thumbnail TYPE and its sizes:
\"s\"  box   100x100
\"m\"  box   320x320
\"x\"  box   800x800
\"y\"  box   1280x1280
\"w\"  box   2560x2560
\"a\"  crop  160x160
\"b\"  crop  320x320
\"c\"  crop  640x640
\"d\"  crop  1280x1280"
  `(cl-find ,type ,thumbnails :test 'string= :key (telega--tl-prop :type)))

(defun telega-photo--highres (photo)
  "Return thumbnail of highest resolution for the PHOTO.
Return thumbnail that can be downloaded."
  (or (cl-some (lambda (tn)
                 (let ((tn-file (telega-file--renew tn :photo)))
                   (when (or (telega-file--downloaded-p tn-file)
                             (telega-file--can-download-p tn-file))
                     tn)))
               ;; From highest res to lower
               (reverse (plist-get photo :sizes)))

      ;; Fallback to the very first thumbnail
      (aref (plist-get photo :sizes) 0)))

(defun telega-photo--thumb (photo)
  "While downloading best photo, get small thumbnail for the PHOTO."
  (let ((photo-sizes (plist-get photo :sizes)))
    (or (cl-some (lambda (tn)
                   (when (telega-file--downloaded-p
                          (telega-file--renew tn :photo))
                     tn))
                 photo-sizes)
        (cl-some (lambda (tn)
                   (when (telega-file--downloading-p
                          (telega-file--renew tn :photo))
                     tn))
                 photo-sizes)
        (cl-some (lambda (tn)
                   (when (telega-file--can-download-p
                          (telega-file--renew tn :photo))
                     tn))
                 photo-sizes)
        )))

(defun telega-photo--best (photo &optional limits)
  "Select best thumbnail from PHOTO suiting LIMITS.
By default LIMITS is `telega-photo-size-limits'."
  (unless limits
    (setq limits telega-photo-size-limits))

  (let ((lim-tw (telega-chars-xwidth (nth 2 limits)))
        (lim-th (telega-chars-xheight (nth 3 limits)))
        ret)
    (seq-doseq (thumb (plist-get photo :sizes))
      (let* ((thumb-file (telega-file--renew thumb :photo))
             (tw (plist-get thumb :width))
             (th (plist-get thumb :height)))
        ;; NOTE: By default (not ret) use any downloadable file, even
        ;; if size does not fits
        ;; Select sizes larger then limits, because downscaling works
        ;; betten then upscaling
        (when (and (or (telega-file--downloaded-p thumb-file)
                       (and (telega-file--can-download-p thumb-file)
                            (not (telega-file--downloaded-p
                                  (plist-get ret :photo)))))

                   (or (not ret)
                       (and (> tw lim-tw)
                            (> th lim-th))
                       ;; NOTE: prefer thumbs with `:progressive_sizes'
                       (and (= tw lim-tw)
                            (= tw lim-tw)
                            (not (seq-empty-p
                                  (plist-get thumb :progressive_sizes)))
                            (seq-empty-p (plist-get ret :progressive_sizes)))))
          (setq ret thumb
                lim-tw tw
                lim-th th))))

    (or ret
        ;; Fallback to the very first thumbnail
        (aref (plist-get photo :sizes) 0))))

(defun telega-photo--open (photo &optional for-msg)
  "Download highres PHOTO asynchronously and open it as a file.
If FOR-MSG is non-nil, then FOR-MSG is message containing PHOTO."
  (let* ((hr (telega-photo--highres photo))
         (hr-file (telega-file--renew hr :photo)))
    (telega-file--download hr-file
      :priority 32
      :update-callback
      (lambda (tl-file)
        (when for-msg
          (telega-msg-redisplay for-msg))
        (when (telega-file--downloaded-p tl-file)
          (when (telega--tl-get for-msg :content :is_secret)
            (telega--openMessageContent for-msg))
          (if (memq 'photo telega-open-message-as-file)
              (telega-open-file (telega--tl-get tl-file :local :path) for-msg)
            (telega-image-view-file tl-file for-msg)))))))


(defun telega-image-supported-file-p (filename &optional error-if-unsupported)
  "Same as `image-supported-file-p'.
Trigger an error if ERROR-IF-UNSUPPORTED is specified and FILENAME is
not natively supported."
  (or (funcall (if (fboundp 'image-supported-file-p)
                   'image-supported-file-p
                 'image-type-from-file-name)
               filename)
      (and error-if-unsupported
           (error "telega: \"%s\" image's format is unsupported"
                  filename))))

(defun telega-image--telega-text (img &optional slice-num)
  "Return text version for image IMG and its slice SLICE-NUM.
Return nil if `:telega-text' is not specified in IMG."
  (let ((tt (plist-get (cdr img) :telega-text)))
    (cond ((null tt) nil)
          ((and (stringp tt) (string-empty-p tt)) nil)
          ((stringp tt) tt)
          ((listp tt)
           (if slice-num
               (progn
                 (cl-assert (> (length tt) slice-num))
                 (nth slice-num tt))
             (mapconcat 'identity tt "\n")))
          (t (cl-assert nil nil "Invalid value for :telega-text=%S" tt)))))

(defun telega-media--cheight-for-limits (width height limits)
  "Calculate cheight for image of WIDTHxHEIGHT size fitting into LIMITS."
  (let* ((width (or width (nth 0 limits)))
         (height (or height (nth 1 limits)))
         (ratio (min (/ (float (telega-chars-xwidth (nth 2 limits))) width)
                     (/ (float (telega-chars-xheight (nth 3 limits))) height))))
    (if (< ratio 1.0)
        (telega-chars-in-height (floor (* height ratio)))

      (let ((cheight (telega-chars-in-height height)))
        (if (< cheight (nth 1 limits))
            (nth 1 limits)
          (cl-assert (<= cheight (nth 3 limits)))
          cheight))
      )))

(defun telega-media--progress-svg (file width height cheight)
  "Generate svg showing downloading progress for FILE."
  (let ((svg (telega-svg-create (if (telega-zerop width) 100 width)
                                (if (telega-zerop height) 100 height))))
    (telega-svg-progress svg (telega-file--downloading-progress file) t)
    (telega-svg-image svg
      :scale 1.0
      :height (telega-ch-height cheight)
      :telega-nslices cheight
      :ascent 'center)))

(defsubst telega-photo--progress-svg (photo cheight)
  "Generate svg for the PHOTO."
  (telega-media--progress-svg
   (telega-file--renew photo :photo)
   (plist-get photo :width)
   (plist-get photo :height)
   cheight))

(defun telega-media--create-image (file width height &optional cheight
                                        progressive-sizes)
  "Create image to display FILE.
WIDTH and HEIGHT specifies size of the FILE's image.
CHEIGHT is the height in chars to use (default=1).
PROGRESSIVE-SIZES specifies list of jpeg's progressive file sizes."
  (unless cheight
    (setq cheight 1))
  (let* ((local-file (plist-get file :local))
         (partial-size
          (when (and (not (seq-empty-p progressive-sizes))
                     (telega-file--downloading-p file)
                     (zerop (plist-get local-file :download_offset))
                     (>= (plist-get local-file :downloaded_prefix_size)
                         (seq-first progressive-sizes)))
            (cl-find (plist-get local-file :downloaded_prefix_size)
                     (seq-reverse progressive-sizes) :test #'>=)))
         (image-filename
          (cond ((telega-file--downloaded-p file)
                 (plist-get local-file :path))
                (partial-size
                 ;; NOTE: Handle case when file is partially
                 ;; downloaded and some progressive size is
                 ;; reached. In this case create temporary image file
                 ;; writing corresponding progress bytes into it and
                 ;; displaying it
                 (let* ((tl-filepath (plist-get local-file :path))
                        (tmp-fname (expand-file-name
                                    (format "%s-%d.%s"
                                            (file-name-base tl-filepath)
                                            partial-size
                                            (file-name-extension tl-filepath))
                                    telega-temp-dir))
                       (coding-system-for-write 'binary))
                   (unless (file-exists-p tmp-fname)
                     (telega-debug "Creating progressive img: %d / %S -> %s"
                                   (telega-file--downloaded-size file)
                                   progressive-sizes
                                   tmp-fname)
                     (with-temp-buffer
                       (set-buffer-multibyte nil)
                       (insert-file-contents-literally tl-filepath)
                       (write-region 1 (+ 1 partial-size) tmp-fname nil 'quiet)))
                   tmp-fname)))))
    (if image-filename
        (telega-create-image
            (if (string-empty-p image-filename)
                (telega-etc-file "non-existing.jpg")
              image-filename)
            nil nil
          :height (telega-ch-height cheight)
          :telega-nslices cheight
          :scale 1.0
          :ascent 'center)
      (telega-media--progress-svg file width height cheight))))

(defun telega-minithumb--create-image (minithumb cheight)
  "Create image and use MINITHUMB minithumbnail as data."
  (telega-create-image
      (base64-decode-string (plist-get minithumb :data))
      (if (and (fboundp 'image-transforms-p)
               (funcall 'image-transforms-p))
          'jpeg
        (when (fboundp 'imagemagick-types)
          'imagemagick))
      t
    :height (telega-ch-height cheight)
    :telega-nslices cheight
    :scale 1.0
    :ascent 'center))

(defun telega-thumb--create-image (thumb &optional _file cheight)
  "Create image for the thumbnail THUMB.
THUMB could be `photoSize' or `thumbnail'.
CHEIGHT is the height in chars (default=1)."
  (telega-media--create-image
   (let ((thumb-tl-type (telega--tl-type thumb)))
     (if (eq thumb-tl-type 'photoSize)
         (telega-file--renew thumb :photo)
       (cl-assert (eq thumb-tl-type 'thumbnail))
       (telega-file--renew thumb :file)))
   (plist-get thumb :width)
   (plist-get thumb :height)
   cheight
   (append (plist-get thumb :progressive_sizes) nil)))

(defun telega-thumb--create-image-one-line (thumb &optional file)
  "Create image for thumbnail (photoSize) for one line use."
  (telega-thumb--create-image thumb file 1))

(defun telega-thumb--create-image-two-lines (thumb &optional file)
  "Create image for thumbnail (photoSize) for two lines use."
  (telega-thumb--create-image thumb file 2))

(defun telega-thumb--create-image-three-lines (thumb &optional file)
  "Create image for thumbnail (photoSize) for three lines use."
  (telega-thumb--create-image thumb file 3))

(defun telega-thumb--create-image-as-is (thumb &optional file)
  "Create image for thumbnail THUMB (photoSize) with size as is."
  (telega-thumb--create-image
   thumb file (telega-chars-in-height (plist-get thumb :height))))

(defun telega-thumb-or-minithumb--create-image (tl-obj &optional _file
                                                       custom-thumb
                                                       custom-minithumb)
  "Create image fol TL-OBJ that has :thumbnail and/or :minithumbnail prop."
  (let* ((thumb (or custom-thumb (plist-get tl-obj :thumbnail)))
         (thumb-cheight (telega-media--cheight-for-limits
                         (plist-get thumb :width)
                         (plist-get thumb :height)
                         telega-thumbnail-size-limits))
         (thumb-file (telega-file--renew thumb :file))
         (minithumb (or custom-minithumb (plist-get tl-obj :minithumbnail))))
    (cond ((telega-file--downloaded-p thumb-file)
           (telega-thumb--create-image
            thumb thumb-file thumb-cheight))
          (minithumb
           (telega-minithumb--create-image
            minithumb thumb-cheight))
          (t
           (telega-thumb--create-image
            thumb thumb-file thumb-cheight)))))

(defvar telega-preview--create-svg-one-line-function nil
  "Bind this to alter `telega-photo-preview--create-image-one-line' and
`telega-video-preview--create-image-one-line' behaviour.")

(defvar telega-preview--inhibit-cached-preview nil
  "Bind to non-nil to inhibit cached preview image in
`telega-photo-preview--create-image-one-line' and
`telega-video-preview--create-image-one-line'.")

(defun telega-photo-preview--create-image-one-line (photo &optional for-chat)
  "Return one line preview image for the PHOTO.
Return nil if preview image is unavailable."
  (when (and telega-use-images
             (telega-chat-match-p for-chat telega-use-one-line-preview-for))
    (let* ((create-svg-fun (or telega-preview--create-svg-one-line-function
                               #'telega-photo-preview--create-svg-one-line))
           (best (telega-photo--best photo '(1 1 1 1)))
           (minithumb (plist-get photo :minithumbnail))
           (cached-preview (unless telega-preview--inhibit-cached-preview
                             (plist-get photo :telega-preview-1)))
           (preview-new
            (cond ((and (telega-file--downloaded-p (plist-get best :photo))
                        (not (eq 'best (car cached-preview))))
                   (cons 'best
                         (funcall create-svg-fun
                                  (telega--tl-get best :photo :local :path)
                                  nil
                                  (plist-get best :width)
                                  (plist-get best :height))))
                  (cached-preview
                   cached-preview)
                  (minithumb
                   (cons 'mini
                         (funcall create-svg-fun
                                  (base64-decode-string
                                   (plist-get minithumb :data))
                                  t
                                  (plist-get minithumb :width)
                                  (plist-get minithumb :height)))))))
      (plist-put photo :telega-preview-1 preview-new)
      (cdr preview-new))))

(defun telega-video-preview--create-image-one-line (video &optional for-chat)
  "Return one line preview for the VIDEO.
Return nil if preview image is unavailable."
  (when (and telega-use-images
             (telega-chat-match-p for-chat telega-use-one-line-preview-for))
    (let* ((create-svg-fun (or telega-preview--create-svg-one-line-function
                               #'telega-video-preview--create-svg-one-line))
           (thumb (plist-get video :thumbnail))
           (minithumb (plist-get video :minithumbnail))
           (cached-preview (unless telega-preview--inhibit-cached-preview
                             (plist-get video :telega-preview-1)))
           (preview-new
            (cond ((and thumb
                        (memq (telega--tl-type (plist-get thumb :format))
                              '(thumbnailFormatJpeg thumbnailFormatPng))
                        (telega-file--downloaded-p (plist-get thumb :file))
                        (not (eq 'best (car cached-preview))))
                   (cons 'best
                         (funcall create-svg-fun
                                  (telega--tl-get thumb :file :local :path)
                                  nil
                                  (plist-get thumb :width)
                                  (plist-get thumb :height))))
                  (cached-preview
                   cached-preview)
                  (minithumb
                   (cons 'mini
                         (funcall create-svg-fun
                                  (base64-decode-string
                                   (plist-get minithumb :data))
                                  t
                                  (plist-get minithumb :width)
                                  (plist-get minithumb :height)))))))
      (plist-put video :telega-preview-1 preview-new)
      (cdr preview-new))))

(defun telega-audio--create-image (audio &optional file)
  "Function to create image for AUDIO album cover."
  (telega-thumb-or-minithumb--create-image
   audio file
   (plist-get audio :album_cover_thumbnail)
   (plist-get audio :album_cover_minithumbnail)))

(defun telega-video--create-image (video &optional file)
  "Create image to preview VIDEO content."
  (if (not telega-use-svg-base-uri)
      (telega-thumb-or-minithumb--create-image video file)

    ;; SVG's `:base-uri' is available
    (let* ((thumb (plist-get video :thumbnail))
           (thumb-file (telega-file--renew thumb :file))
           (minithumb (plist-get video :minithumbnail))
           (v-width (plist-get video :width))
           (v-height (plist-get video :height))
           (cheight (telega-media--cheight-for-limits
                     v-width v-height telega-video-size-limits))
           (svg (telega-svg-create v-width v-height))
           (base-uri-fname ""))
      (cond ((and (memq (telega--tl-type (plist-get thumb :format))
                        '(thumbnailFormatJpeg thumbnailFormatPng))
                  (telega-file--downloaded-p thumb-file))
             (setq base-uri-fname (telega--tl-get thumb-file :local :path))
             (telega-svg-embed-image-fitting
              svg base-uri-fname nil
              (plist-get thumb :width) (plist-get thumb :height)))

            (minithumb
             (telega-svg-embed-image-fitting
              svg (base64-decode-string (plist-get minithumb :data)) t
              (plist-get minithumb :width) (plist-get minithumb :height))))

      (telega-svg-white-play-triangle-in-circle svg)
      (telega-svg-image svg
        :scale 1.0
        :ascent 'center
        :height (telega-ch-height cheight)
        :telega-nslices cheight
        :base-uri base-uri-fname))))

(defun telega-media--image-update (obj-spec file &optional cache-prop)
  "Called to update the image contents for the OBJ-SPEC.
OBJ-SPEC is cons of object and create image function.
Create image function accepts two arguments - object and FILE.
Return updated image, cached or created with create image function.

CACHE-PROP specifies property name to cache image at OBJ-SPEC.
Default is `:telega-image'."
  (let ((cached-image (plist-get (car obj-spec) (or cache-prop :telega-image)))
        (simage (funcall (cdr obj-spec) (car obj-spec) file)))
    ;; NOTE: Sometimes `create' function returns nil results
    ;; Probably, because Emacs has no access to the image file while
    ;; trying to convert sticker from webp to png
    (when (and telega-use-images (not simage))
      (error "telega: [BUG] Image create (%S %S) -> nil"
             (car obj-spec) file))

    (unless (equal cached-image simage)
      ;; Update the image
      (if cached-image
          (setcdr cached-image (cdr simage))
        (setq cached-image simage))

      ;; NOTE: We call `image-flush' because only filename in
      ;; the image spec can be changed (during animation for
      ;; example), and image caching won't notice this because
      ;; `(sxhash cached-image)' and `(sxhash simage)' might
      ;; return the same!
      ;;
      ;; We do it under `ignore-errors' to avoid any image related errors
      ;; see https://github.com/zevlg/telega.el/issues/349
      ;; and https://t.me/emacs_telega/33101
      (when telega-use-images
        (ignore-errors (image-flush cached-image)))

      (plist-put (car obj-spec) (or cache-prop :telega-image) cached-image))
    cached-image))

(defun telega-media--image (obj-spec file-spec &optional force-update cache-prop)
  "Return image for media object specified by OBJ-SPEC.
File is specified with FILE-SPEC.
CACHE-PROP specifies property name to cache image at OBJ-SPEC.
Default is `:telega-image'."
  (let ((cached-image (plist-get (car obj-spec) (or cache-prop :telega-image))))
    (when (or force-update (not cached-image))
      (let ((media-file (telega-file--renew (car file-spec) (cdr file-spec))))
        ;; First time image is created or update is forced
        (setq cached-image
              (telega-media--image-update obj-spec media-file cache-prop))

        ;; Possibly initiate file downloading
        (when (and telega-use-images
                   (or (telega-file--need-download-p media-file)
                       (telega-file--downloading-p media-file)))
          (telega-file--download media-file
            :update-callback
            (lambda (dfile)
              (when (telega-file--downloaded-p dfile)
                (telega-media--image-update obj-spec dfile cache-prop)
                (force-window-update)))))))
    cached-image))

(cl-defun telega-media--image-updateNEW (obj)
  "Update media image for the OBJ."
  (let* ((media-spec (plist-get obj :telega-media-spec))
         (image-create-func (plist-get media-spec :image-create-func))
         (cache-prop (plist-get media-spec :cache-prop))
         (cached-image (plist-get obj cache-prop))
         (simage (funcall image-create-func obj)))
    ;; NOTE: Sometimes `create' function returns nil results
    ;; Probably, because Emacs has no access to the image file while
    ;; trying to convert sticker from webp to png
    (when (and telega-use-images (not simage))
      (error "telega: [BUG] Image create (%S %S) -> nil"
             image-create-func obj))

    (unless (equal cached-image simage)
      ;; NOTE: We call `image-flush' because only filename in
      ;; the image spec can be changed (during animation for
      ;; example), and image caching won't notice this because
      ;; `(sxhash cached-image)' and `(sxhash simage)' might
      ;; return the same!
      ;;
      ;; We do it under `ignore-errors' to avoid any image related errors
      ;; see https://github.com/zevlg/telega.el/issues/349
      ;; and https://t.me/emacs_telega/33101
      (when telega-use-images
        (ignore-errors (image-flush cached-image)))

      ;; Update the image
      (if cached-image
          (setcdr cached-image (cdr simage))
        (setq cached-image simage))

      (plist-put obj cache-prop cached-image))
    cached-image))

(cl-defun telega-media--imageNEW (obj &key create-image-function cheight
                                      cache-prop)
  (let ((cached-image (plist-get (car obj-spec) (or cache-prop :telega-image))))
    (when (or force-update (not cached-image))
      (let ((media-file (telega-file--renew (car file-spec) (cdr file-spec))))
        ;; First time image is created or update is forced
        (setq cached-image
              (telega-media--image-update obj-spec media-file cache-prop))

        ;; Possibly initiate file downloading
        (when (and telega-use-images
                   (or (telega-file--need-download-p media-file)
                       (telega-file--downloading-p media-file)))
          (telega-file--download media-file
            :update-callback
            (lambda (dfile)
              (when (telega-file--downloaded-p dfile)
                (telega-media--image-update obj-spec dfile cache-prop)
                (force-window-update)))))))
    cached-image))

(defun telega-photo--image (photo limits)
  "Return best suitable image for the PHOTO."
  (let* ((best (telega-photo--best photo limits))
         (cheight (telega-media--cheight-for-limits
                   (plist-get best :width)
                   (plist-get best :height)
                   limits))
         (create-image-fun
          (progn
            (cl-assert (> cheight 0))
            (cl-assert (<= cheight (nth 3 limits)))
            (lambda (_photoignored &optional _fileignored)
              ;; 1) FILE downloaded, show photo
              ;; 2) Thumbnail is downloaded, use it
              ;; 2.5) Minithumbnail is available, use it
              ;; 3) FILE downloading, fallback to progress svg
              (or (let ((best-file (telega-file--renew best :photo)))
                    (when (telega-file--downloaded-p best-file)
                      (telega-thumb--create-image best best-file cheight)))
                  (let* ((thumb (telega-photo--thumb photo))
                         (thumb-file (telega-file--renew thumb :photo)))
                    (when (telega-file--downloaded-p thumb-file)
                      (telega-thumb--create-image thumb thumb-file cheight)))
                  (when-let ((minithumb (plist-get photo :minithumbnail)))
                    (telega-minithumb--create-image minithumb cheight))
                  (telega-photo--progress-svg best cheight))))))

    (telega-media--image
     (cons photo create-image-fun)
     (cons best :photo)
     'force-update)))

(defun telega-avatar-text-simple (sender wchars)
  "Create textual avatar for the SENDER (chat or user).
WCHARS is number of chars in width used for the avatar.
To be used as `telega-avatar-text-function'."
  (let ((title (telega-msg-sender-title sender)))
    (concat "(" (substring title 0 1) ")"
            (when (> wchars 3)
              (make-string (- wchars 3) ?\s)))))

(defun telega-avatar-text-composed (sender wchars)
  "Return avatar text as text with composed `telega-symbol-circle' char.
To be used as `telega-avatar-text-function'."
  (let ((title (telega-msg-sender-title sender)))
    (concat (propertize (compose-chars (aref telega-symbol-circle 0)
                                       (aref title 0))
                        'face (telega-msg-sender-title-faces sender))
            (make-string wchars ?\s))))

(defun telega-avatar--create-image (sender file &optional cheight addon-function)
  "Create SENDER (char or user) avatar image.
CHEIGHT specifies avatar height in chars, default is 2."
  ;; NOTE:
  ;; - For CHEIGHT==1 align avatar at vertical center
  ;; - For CHEIGHT==2 make svg height to be 3 chars, so if font size
  ;;   is increased, there will be no gap between two slices
  (unless cheight (setq cheight 2))
  (let* ((base-dir (telega-directory-base-uri telega-database-dir))
         (photofile (telega--tl-get file :local :path))
         (factors (alist-get cheight telega-avatar-factors-alist))
         (cfactor (or (car factors) 0.9))
         (mfactor (or (cdr factors) 0.1))
         (xh (telega-chars-xheight cheight))
         (margin (* mfactor xh))
         (ch (* cfactor xh))
         (cfull (floor (+ ch margin)))
         (aw-chars (telega-chars-in-width ch))
         (svg-xw (telega-chars-xwidth aw-chars))
         (svg-xh (cond ((= cheight 1) cfull)
                       ((= cheight 2) (+ cfull (telega-chars-xheight 1)))
                       (t xh)))
         (svg (telega-svg-create svg-xw svg-xh)))
    (if (telega-file-exists-p photofile)
        (let ((img-type (telega-image-supported-file-p photofile))
              (clip (telega-svg-clip-path svg "clip")))
          (svg-circle clip (/ svg-xw 2) (/ cfull 2) (/ ch 2))
          (telega-svg-embed svg (list (file-relative-name photofile base-dir)
                                      base-dir)
                            (format "image/%S" img-type)
                            nil
                            :x (/ (- svg-xw ch) 2) :y (/ margin 2)
                            :width ch :height ch
                            :clip-path "url(#clip)"))

      ;; Draw initials
      (let* ((telega-palette-context 'avatar)
             (palette (telega-msg-sender-palette sender))
             (c1 (telega-color-name-as-hex-2digits
                  (or (telega-palette-attr palette :background) "gray75")))
             (c2 (telega-color-name-as-hex-2digits
                  (or (telega-palette-attr palette :foreground) "gray25"))))
        (svg-gradient svg "cgrad" 'linear (list (cons 0 c1) (cons ch c2))))
      (svg-circle svg (/ svg-xw 2) (/ cfull 2) (/ ch 2) :gradient "cgrad")
      (let ((font-size (/ ch 2)))
        (svg-text svg (telega-msg-sender-initials sender)
                  :font-size font-size
                  :font-weight "bold"
                  :fill "white"
                  :font-family "monospace"
                  :x "50%"
                  :text-anchor "middle" ; makes text horizontally centered
                  ;; XXX: Insane y calculation
                  :y (+ (/ font-size 3) (/ cfull 2))
                  )))

    ;; XXX: Apply additional function, used by `telega-patrons-mode'
    ;; Also used to outline currently speaking users in voice chats
    (when addon-function
      (funcall addon-function svg (list (/ svg-xw 2) (/ cfull 2) (/ ch 2))))

    (telega-svg-image svg
      :scale 1.0
      :width (telega-cw-width aw-chars)
      :ascent 'center
      :mask 'heuristic
      :base-uri (expand-file-name "dummy" base-dir)
      ;; Correct text for tty-only avatar display
      :telega-text
      (cons (let ((ava-text (funcall telega-avatar-text-function
                                     sender aw-chars)))
              (if (> (length ava-text) aw-chars)
                  (substring ava-text 0 aw-chars)
                ava-text))
            (mapcar (lambda (_ignore)
                      (make-string aw-chars ?\u00A0))
                    (make-list (1- cheight) 'not-used))))
    ))

(defun telega-avatar--create-image-one-line (sender file)
  "Create SENDER (chat or user) avatar image for one line use."
  (telega-avatar--create-image sender file 1))

(defun telega-avatar--create-image-three-lines (sender file)
  "Create SENDER (chat or user) avatar image for three lines use."
  (telega-avatar--create-image sender file 3))

(defun telega-msg-sender-avatar-image (msg-sender
                                       &optional create-image-fun
                                       force-update cache-prop)
  "Create avatar image for the MSG-SENDER.
By default CREATE-IMAGE-FUN is `telega-avatar--create-image'."
  (cl-assert msg-sender)
  (telega-media--image
   (cons msg-sender (or create-image-fun #'telega-avatar--create-image))
   (if (telega-user-p msg-sender)
       (cons (plist-get msg-sender :profile_photo) :small) ;user
     (cl-assert (telega-chat-p msg-sender))
     (cons (plist-get msg-sender :photo) :small)) ;chat
   force-update cache-prop))

(defun telega-msg-sender-avatar-image-one-line (msg-sender
                                                &optional create-image-fun
                                                force-update cache-prop)
  "Create one-line avatar for the MSG-SENDER.
By default CREATE-IMAGE-FUN is `telega-avatar--create-image-one-line'."
  (telega-msg-sender-avatar-image
   msg-sender (or create-image-fun #'telega-avatar--create-image-one-line)
   force-update (or cache-prop :telega-avatar-1)))

(defun telega-msg-sender-avatar-image-three-lines (msg-sender
                                                   &optional create-image-fun
                                                   force-update cache-prop)
  "Create three lines avatar for the MSG-SENDER.
By default CREATE-IMAGE-FUN is `telega-avatar--create-image-three-lines'."
  (telega-msg-sender-avatar-image
   msg-sender (or create-image-fun #'telega-avatar--create-image-three-lines)
   force-update (or cache-prop :telega-avatar-3)))

(defun telega-chat-photo-info--image (chat-photo-info
                                      &optional cheight force-update)
  "Create image for chatPhotoInfo TL structure."
  (let* ((cheight (or cheight 2))
         (create-image-fun
          (lambda (_photoignored &optional _fileignored)
            (let ((small-file (plist-get chat-photo-info :small)))
              (cond ((telega-file--downloaded-p small-file)
                     ;; From TDLib docs: @small A small (160x160)
                     ;; chat photo variant in JPEG format.
                     (telega-media--create-image small-file 160 160 cheight))
                    ((plist-get chat-photo-info :minithumbnail)
                     (telega-minithumb--create-image
                      (plist-get chat-photo-info :minithumbnail) cheight))
                    (t
                     ;; TODO: Fallback to svg rendering
                     ))))))
    (telega-media--image
     (cons chat-photo-info create-image-fun)
     (cons chat-photo-info :small)
     force-update
     (intern (format ":telega-%d-lines" cheight)))))

(defun telega-chat-photo-info-image-one-line (chat-photo-info
                                              &optional force-update)
  "Create image for chatPhotoInfo TL structure."
  (telega-chat-photo-info--image chat-photo-info 1 force-update))


;; Location
(defun telega-map--embed-sender (svg map sender sender-loc)
  "Embed sender to the location map.
SENDER can be a nil, meaning venue location is to be displayed."
  (let* ((base-dir (telega-directory-base-uri telega-database-dir))
         (width (plist-get map :width))
         (height (plist-get map :height))
         (map-loc (plist-get map :map-location)) ;at image center
         (raw-map-sender (plist-get map :sender_id))
         (map-sender (when raw-map-sender
                       (telega-msg-sender raw-map-sender)))
         (user-loc sender-loc)
         (user-loc-off
          (telega-location-distance map-loc user-loc 'components))
         (user-y (+ (/ height 2)
                    (telega-map--distance-pixels
                     (car user-loc-off) user-loc (plist-get map :zoom))))
         (user-x (+ (/ width 2)
                    (telega-map--distance-pixels
                     (cdr user-loc-off) user-loc (plist-get map :zoom))))
         (sender-shown-p nil))
    ;; NOTE: Always show map sender, otherwise show sender only if it
    ;; fits into map image
    (when-let* ((show-sender-p (and sender
                                    (or (eq sender map-sender)
                                        (and (< 0 user-x width)
                                             (< 0 user-y height)))))
                (sender-photo (if (telega-user-p sender)
                                  (telega--tl-get sender :profile_photo :small)
                                (cl-assert (telega-chat-p sender))
                                (telega--tl-get sender :photo :small))))
      (when (telega-file--downloaded-p sender-photo)
        (let* ((photofile (telega--tl-get sender-photo :local :path))
               (img-type (telega-image-supported-file-p photofile))
               (clip-name (make-temp-name "user-clip"))
               (clip (telega-svg-clip-path svg clip-name))
               (sz (/ (plist-get map :height) 8))
               (sz2 (/ sz 2)))
          (svg-circle clip (+ user-x sz2) (- user-y sz2) sz2)
          (svg-polygon clip (list (cons user-x user-y)
                                  (cons (+ user-x (/ sz2 4))
                                        (- user-y sz2))
                                  (cons (+ user-x sz2)
                                        (- user-y (/ sz2 4)))))
          (telega-svg-embed svg (list (file-relative-name photofile base-dir)
                                      base-dir)
                            (format "image/%S" img-type) nil
                            :x user-x :y (- user-y sz)
                            :width sz :height sz
                            :clip-path (format "url(#%s)" clip-name)))
        (setq sender-shown-p t)))

    (cond ((or (null sender) (eq sender map-sender))
           ;; Always show dot for map sender
           (svg-circle svg user-x user-y 8
                       :stroke-width 4
                       :stroke-color "white"
                       :fill-color (face-foreground 'telega-blue))

           ;; User's direction heading 1-360, 0 if unknown
           (let ((heading (or (plist-get map :user-heading) 0)))
             (unless (zerop heading)
               (let* ((w2 user-x)
                      (h2 user-y)
                      (angle1 (* float-pi (/ (- (+ heading 200)) 180.0)))
                      (angle2 (* float-pi (/ (- (+ heading 160)) 180.0)))
                      (h-dx1 (* 100 (sin angle1)))
                      (h-dy1 (* 100 (cos angle1)))
                      (h-dx2 (* 100 (sin angle2)))
                      (h-dy2 (* 100 (cos angle2)))
                      (hclip (telega-svg-clip-path svg "headclip")))
                 (telega-svg-path hclip (format "M %d %d L %f %f L %f %f Z"
                                                w2 h2 (+ w2 h-dx1) (+ h2 h-dy1)
                                                (+ w2 h-dx2) (+ h2 h-dy2)))
                 (telega-svg-gradient
                  svg "headgrad" 'radial
                  (list (list 0 (telega-color-name-as-hex-2digits
                                 (face-foreground 'telega-blue))
                              :opacity 0.9)
                        ;; (list 50 (telega-color-name-as-hex-2digits
                        ;;           (face-foreground 'telega-blue))
                        ;;       :opacity 0.5)
                        (list 100 (telega-color-name-as-hex-2digits
                                   (face-foreground 'telega-blue))
                              :opacity 0.0)))
                 (svg-circle svg w2 h2 50
                             :gradient "headgrad"
                             :clip-path "url(#headclip)")
                 )))

           ;; Proximity Alert Radius
           (let* ((alert-radius (or (plist-get map :user-alert-radius) 0))
                  (radius-px (unless (zerop alert-radius)
                               (telega-map--distance-pixels
                                alert-radius
                                (plist-get map :user-location)
                                (plist-get map :zoom)))))
             (when radius-px
               (svg-circle svg user-x user-y radius-px
                           :fill "none"
                           :stroke-dasharray "4 6"
                           :stroke-width 4
                           :stroke-opacity "0.6"
                           :stroke-color "black")))
           )

          (sender-shown-p
           (svg-circle svg user-x user-y 4
                       :stroke-width 2
                       :stroke-color "white"
                       :fill-color "black")))

    (or (eq sender map-sender) sender-shown-p)))

(defun telega-map--create-image (map &optional _file)
  "Create map image for location MAP."
  (let* ((base-dir (telega-directory-base-uri telega-database-dir))
         (map-photo (telega-file--renew map :photo))
         (map-photofile (when map-photo
                          (telega--tl-get map-photo :local :path)))
         ;; NOTE: `raw-map-sender' is nil for `venue' locations
         (raw-map-sender (plist-get map :sender_id))
         (map-sender (when raw-map-sender
                       (telega-msg-sender raw-map-sender)))
         (width (plist-get map :width))
         (height (plist-get map :height))
         (svg (telega-svg-create width height)))
    (cl-assert (and (integerp width) (integerp height)))
    (if (and (telega-file--downloaded-p map-photo)
             (telega-file-exists-p map-photofile))
        (telega-svg-embed svg (list (file-relative-name map-photofile base-dir)
                                    base-dir)
                          "image/png" nil
                          :x 0 :y 0 :width width :height height)
      (svg-rectangle svg 0 0 width height
                     :fill-color (telega-color-name-as-hex-2digits
                                  (or (face-foreground 'telega-shadow) "gray50"))))

    ;; TODO: show other users close enough to `:sender_id'

    ;; NOTE: First draw other users
    (when (and telega-location-show-me
               telega-my-location
               (not (telega-me-p map-sender)))
      (telega-map--embed-sender svg map (telega-user-me) telega-my-location))

    ;; Show map sender with heading and proximity alert zone
    ;; NOTE: map sender can be nil for venue messages
    (telega-map--embed-sender svg map map-sender (plist-get map :user-location))

    (telega-svg-image svg
      :scale 1.0
      :width width :height height
      :ascent 'center
      :base-uri (expand-file-name "dummy" base-dir))))

;; See
;; https://wiki.openstreetmap.org/wiki/Slippy_map_tilenames#Resolution_and_Scale
(defun telega-map--distance-pixels (meters loc zoom)
  "Convert METERS distance at LOC to the pixels distance at ZOOM level."
  (let ((lat (plist-get loc :latitude)))
    (round (/ meters
              (/ (* 156543.03 (cos (degrees-to-radians lat)))
                 (expt 2 zoom))))))

(defun telega-map--need-new-map-photo-p (map loc)
  "Return non-nil if need to fetch new map photo for new user location LOC."
  (or (and (not (plist-get map :photo))
           (not (plist-get map :get-map-extra)))
      (not loc)
      (not (plist-get map :map-location))
      (let* ((map-xh (telega-chars-xheight (car telega-location-size)))
             (distance
              (telega-location-distance (plist-get map :map-location) loc))
             (distance-px (telega-map--distance-pixels
                           distance loc (plist-get map :zoom))))
        (> distance-px (/ map-xh 4)))))

(defun telega-map--get-thumbnail-file (map loc &optional msg)
  "Request MAP image at LOC location for MSG.
Update `:svg-image' when new image is received."
  (telega--getMapThumbnailFile
      loc (plist-get map :zoom)
      (plist-get map :width) (plist-get map :height)
      (plist-get map :scale) (when msg (telega-msg-chat msg))
    (lambda (map-file)
      (plist-put map :map-location loc)
      (plist-put map :photo map-file)

      (telega-file--download map-file
        :priority 24
        :update-callback
        (lambda (mfile)
          (when (telega-file--downloaded-p mfile)
            (let ((svg-image (plist-get map :svg-image))
                  (new-image (telega-map--create-image map mfile)))
              (setcdr svg-image (cdr new-image))
              (force-window-update)))
          (when msg
            (telega-msg-redisplay msg))
          )))))

(defun telega-map--zoom (map step)
  "Change zoom for the MAP by STEP.
Return non-nil if zoom has been changed."
  (let* ((old-zoom (plist-get map :zoom))
         (new-zoom (+ old-zoom step)))
    (cond ((< new-zoom 13)
           (setq new-zoom 13))
          ((> new-zoom 20)
           (setq new-zoom 20)))
    (plist-put map :zoom new-zoom)
    (not (= old-zoom new-zoom))))


;;; TODO: Chat Themes
(defun telega-chat-theme--create-svg (_theme &optional _cheight)
  "Create svg for chat THEME."
;;   (let ((cheight (or cheight 6))
;; ;        (svg (telega-svg-create width height))
;;         )
;;     ;; TODO: draw theme

;;     svg)
  )

(defun telega-chat-theme--create-image (theme)
  "Create image for the chat THEME."
  (let ((base-dir (telega-directory-base-uri telega-database-dir))
        (svg (telega-chat-theme--create-svg theme)))
    (telega-svg-image svg
      :scale 1.0
      :width (alist-get 'width (nth 1 svg))
      :height (alist-get 'height (nth 1 svg))
      :ascent 'center
      :base-uri (expand-file-name "dummy" base-dir))))


;;; Media layout
(defun telega-media-layout--ratio (w h)
  (/ (float w) h))

(defun telega-media-layout--proportion (w h)
  (let ((ratio (telega-media-layout--ratio w h)))
    (cond ((> ratio 1.2) 'w)
          ((< ratio 0.8) 'n)
          (t 'q))))

(defun telega-media-layout--for-images (sizes)
  "Return layout for the list of the photo SIZES.
Return list of rows."
  (let ((n (length sizes)))
    (cond ((= 1 n)
           )
          )))

(provide 'telega-media)

;;; telega-media.el ends here
