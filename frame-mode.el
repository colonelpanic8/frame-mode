;;; frame-mode.el --- Use frames instead of windows -*- lexical-binding: t; -*-

;; Copyright (C) 2017 Ivan Malison

;; Author: Ivan Malison <IvanMalison@gmail.com>
;; Keywords: frames
;; URL: https://github.com/IvanMalison/frame-mode
;; Version: 0.0.0
;; Package-Requires: ((s "1.9.0") (emacs "24.4"))

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Use frames instead of windows whenever display-buffer is called.

;;; Code:

(require 's)
(require 'cl-lib)

(defgroup frame-mode ()
  "Frames minor mode."
  :group 'frame-mode
  :prefix "frame-mode-")

(defvar frame-keys-mode-keymap
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-x 3") 'make-frame)
    (define-key map (kbd "C-x 2") 'make-frame)
    (define-key map (kbd "C-x o") 'frame-mode-other-window)
    (define-key map (kbd "C-x O") '(lambda ()
                                     (interactive)
                                     (frame-mode-other-window -1)))
    (define-key map (kbd "C-c C-f")
      'frame-mode-other-window-or-frame-next-command)
    map))

(define-minor-mode frame-keys-mode
  "Minor mode that replaces familiar window manipulation key bindings with
commands that do similar things with frames."
  :lighter nil
  :keymap frame-keys-mode-keymap
  :global t
  :group 'frame-mode
  :require 'frame-mode)

;;;###autoload
(define-minor-mode frame-mode
  "Minor mode that uses `display-buffer-alist' to ensure that buffers are
displayed using frames intead of windows."
  :lighter nil
  :keymap nil
  :global t
  :group 'frame-mode
  :require 'frame-mode
  (if frame-mode
      (progn
        (advice-add 'display-buffer :around 'frame-mode-around-display-buffer)
        (unless pop-up-frames
          (setq pop-up-frames 'graphic-only)))
    (setq pop-up-frames nil)))

(defcustom frame-mode-is-frame-viewable-fn
  'frame-mode-default-is-frame-viewable-fn
  "Predicate that determines whether a frame can be used to pop up a buffer."
  :type 'function)

(defun frame-mode-is-frame-viewable (frame)
  (funcall frame-mode-is-frame-viewable-fn frame))

(defun frame-mode-default-is-frame-viewable-fn (frame)
  (if (executable-find "xwininfo")
      (s-contains-p "IsViewable"
                    (shell-command-to-string
                     (format "xwininfo -id %s" (frame-parameter frame 'window-id))))
    (progn
      (message "xwininfo is not on path, not checking if display frame is actually visible.")
      t)))

(defun frame-mode-display-some-frame-predicate (frame)
  (and
   (not (eq frame (selected-frame)))
   (not (window-dedicated-p
         (or
          (get-lru-window frame)
          (frame-first-window frame))))
   (frame-mode-is-frame-viewable frame)))

(defun frame-mode-reuse-some-visible-window (buffer alist)
  (cl-loop for window in (get-buffer-window-list buffer)
           for frame = (window-frame window)
           when (frame-mode-is-frame-viewable frame) return window))

(defcustom frame-mode-is-frame-viewable-fn
  'frame-mode-default-is-frame-viewable-fn
  "Predicate that determines whether a frame can be used to pop up a buffer."
  :type 'function)



;; These variables are for internal use by `frame-only-mode' only.
(defvar frame-mode-use-other-frame-or-window-by-default nil)
(defvar frame-mode-flip-other-frame-behavior nil)

(defun frame-mode-should-use-other-frame-or-window (&rest _args)
  (let ((result (not
                 (eq frame-mode-use-other-frame-or-window-by-default
                     frame-mode-flip-other-frame-behavior))))
    (when frame-mode-flip-other-frame-behavior
      (setq frame-mode-flip-other-frame-behavior nil))
    result))



(defvar frame-mode-display-buffer-alist
 ;; XXX: helm and popup go first here because its unlikely someone would want to
 ;; control where those buffers show up. This avoids unintentionally
 ;; deactivating the effect of `frame-mode-other-window-or-frame-next-command'.
 '(("\\*helm.*" . ((display-buffer-same-window display-buffer-pop-up-window)))
   (".*popup\*" . ((display-buffer-pop-up-window)))
   ("\\*Agenda Commands\\*" . ((display-buffer-pop-up-window)))
   ("\\*Org Agenda\\*" . (display-buffer-full-frame))
   ("\\*Org Select\\*" . ((display-buffer-pop-up-window)))
   ("\\*Org todo\\*" . ((display-buffer-same-window)))
   ("\\*Org Note\\*" . ((display-buffer-pop-up-window)))
   (".*\\*transient\\*.*" . ((display-buffer-in-side-window)))
   ("\\*Completions.\\*" . (display-buffer-same-window))
   ("\\*[Ff]lycheck error.*" .
    ((frame-mode-reuse-some-visible-window
      display-buffer-use-some-frame
      display-buffer-pop-up-frame) .
      ((inhibit-same-window . t)
       (frame-predicate . frame-mode-display-some-frame-predicate)
       (resuable-frame . visible))))
   (".*magit-diff.*" .
    ((display-buffer-pop-up-window) .
     ((reusable-frames . 0)
      (inhibit-switch-frame . t)
      (inhibit-same-window . t))))
   ("\\*register preview\\*" . ((display-buffer-pop-up-window)))
   (frame-mode-should-use-other-frame-or-window .
    ((frame-mode-force-display-buffer-use-some-frame
      frame-mode-force-display-buffer-pop-up-frame) .
      ((inhibit-same-window . t)
       (reusable-frames . visible))))
   (".*" .
    ((frame-mode-reuse-some-visible-window
      display-buffer-same-window
      display-buffer-use-some-frame
      display-buffer-pop-up-frame) .
     ((reusable-frames . visible)
      (frame-predicate . frame-mode-display-some-frame-predicate))))))

(defun frame-mode-around-display-buffer (fn &rest args)
  (let* ((target-alist (if frame-mode frame-mode-display-buffer-alist
                         display-buffer-alist))
         (display-buffer-alist target-alist))
    (apply fn args)))

(defun frame-mode-around-use-new-window (fn &rest args)
  (let* ((frame-mode-use-other-frame-or-window-by-default t))
    (apply fn args)))

(defun frame-mode-always-use-other-frame-for (fn)
  (advice-add fn :around 'frame-mode-around-use-new-window))

;;;###autoload
(defun frame-mode-other-window (count)
  "A version of `other-window' that can jump across frames.

COUNT determines the number of windows to move over."
  (interactive
   (list 1))
  (other-window count 'visible)
  (select-frame-set-input-focus (selected-frame)))

;;;###autoload
(defun frame-mode-other-window-or-frame-next-command ()
  "Use a new frame no matter what when the next call to `display-buffer' occurs."
  (interactive)
  (setq frame-mode-flip-other-frame-behavior
        (not frame-mode-flip-other-frame-behavior))
  (message "using other frame: %s"
           frame-mode-flip-other-frame-behavior))

(provide 'frame-mode)
;;; frame-mode.el ends here
