;;; embark-consult.el --- Consult integration for Embark -*- lexical-binding: t; -*-

;; Copyright (C) 2021, 2022  Free Software Foundation, Inc.

;; Author: Omar Antolín Camarena <omar@matem.unam.mx>
;; Maintainer: Omar Antolín Camarena <omar@matem.unam.mx>
;; Keywords: convenience
;; Version: 0.6
;; Homepage: https://github.com/oantolin/embark
;; Package-Requires: ((emacs "27.1") (embark "0.17") (consult "0.17"))

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This package provides integration between Embark and Consult. The package
;; will be loaded automatically by Embark.

;; Some of the functionality here was previously contained in Embark
;; itself:

;; - Support for consult-buffer, so that you get the correct actions
;; for each type of entry in consult-buffer's list.

;; - Support for consult-line, consult-outline, consult-mark and
;; consult-global-mark, so that the insert and save actions don't
;; include a weird unicode character at the start of the line, and so
;; you can export from them to an occur buffer (where occur-edit-mode
;; works!).

;; Just load this package to get the above functionality, no further
;; configuration is necessary.

;; Additionally this package contains some functionality that has
;; never been in Embark: access to Consult preview from auto-updating
;; Embark Collect buffer that is associated to an active minibuffer
;; for a Consult command. For information on Consult preview, see
;; Consult's info manual or its readme on GitHub.

;; If you always want the minor mode enabled whenever it possible use:

;; (add-hook 'embark-collect-mode-hook #'consult-preview-at-point-mode)

;; If you don't want the minor mode automatically on and prefer to
;; trigger the consult previews manually use this instead:

;; (define-key embark-collect-mode-map (kbd "C-j")
;;   #'consult-preview-at-point)

;;; Code:

(require 'embark)
(require 'consult)

(eval-when-compile
  (require 'cl-lib))

;;; Consult preview from Embark Collect buffers

(defun embark-consult--collect-candidate ()
  "Return candidate at point in collect buffer."
  (cadr (embark-target-collect-candidate)))

(add-hook 'consult--completion-candidate-hook #'embark-consult--collect-candidate)

;;; Support for consult-location

(defun embark-consult--strip (string)
  "Strip substrings marked with the `consult-strip' property from STRING."
  (if (text-property-not-all 0 (length string) 'consult-strip nil string)
      (let ((end (length string)) (pos 0) (chunks))
        (while (< pos end)
          (let ((next (next-single-property-change pos 'consult-strip string end)))
            (unless (get-text-property pos 'consult-strip string)
              (push (substring string pos next) chunks))
            (setq pos next)))
        (apply #'concat (nreverse chunks)))
    string))

(defun embark-consult--target-strip (type target)
  "Remove the unicode suffix character from a TARGET of TYPE."
  (cons type (embark-consult--strip target)))

(setf (alist-get 'consult-location embark-transformer-alist)
      #'embark-consult--target-strip)

(defun embark-consult-goto-location (target)
  "Jump to consult location TARGET."
  (consult--jump (car (consult--get-location target)))
  (pulse-momentary-highlight-one-line (point)))

(setf (alist-get 'consult-location embark-default-action-overrides)
      #'embark-consult-goto-location)

(defun embark-consult-export-occur (lines)
  "Create an occur mode buffer listing LINES.
The elements of LINES are assumed to be values of category `consult-line'."
  (let ((buf (generate-new-buffer "*Embark Export Occur*"))
        (mouse-msg "mouse-2: go to this occurrence")
        last-buf)
    (with-current-buffer buf
      (dolist (line lines)
        (pcase-let*
            ((`(,loc . ,num) (consult--get-location line))
             ;; the text properties added to the following strings are
             ;; taken from occur-engine
             (lineno (propertize (format "%7d:" num)
                                 'occur-prefix t
                                 ;; Allow insertion of text at the end
                                 ;; of the prefix (for Occur Edit mode).
                                 'front-sticky t
                                 'rear-nonsticky t
                                 'occur-target loc
                                 'follow-link t
                                 'help-echo mouse-msg))
             (contents (propertize (embark-consult--strip line)
                                   'occur-target loc
                                   'occur-match t
                                   'follow-link t
                                   'help-echo mouse-msg))
             (nl (propertize "\n" 'occur-target loc))
             (this-buf (marker-buffer loc)))
          (unless (eq this-buf last-buf)
            (insert (propertize
                     (format "lines from buffer: %s\n" this-buf)
                     'face list-matching-lines-buffer-name-face))
            (setq last-buf this-buf))
          (insert (concat lineno contents nl))))
      (goto-char (point-min))
      (occur-mode))
    (pop-to-buffer buf)))

(defun embark-consult--upgrade-markers ()
  "Upgrade consult-location cheap markers to real markers.
This function is meant to be added to `embark-collect-mode-hook'."
  (when (eq embark--type 'consult-location)
    (dolist (entry tabulated-list-entries)
      (when (car entry)
        (consult--get-location (car entry))))))

(setf (alist-get 'consult-location embark-exporters-alist)
      #'embark-consult-export-occur)
(cl-pushnew #'embark-consult--upgrade-markers embark-collect-mode-hook)

;;; Support for consult-grep

(defvar wgrep-header/footer-parser)
(declare-function wgrep-setup "ext:wgrep")

(embark-define-keymap embark-consult-revert-map
  "A keymap with a binding for revert-buffer."
  :parent nil
  ("g" revert-buffer))

(defun embark-consult-export-grep (lines)
  "Create a grep mode buffer listing LINES."
  (let ((buf (generate-new-buffer "*Embark Export Grep*")))
    (with-current-buffer buf
      (insert (propertize "Exported grep results:\n\n" 'wgrep-header t))
      (dolist (line lines) (insert line "\n"))
      (goto-char (point-min))
      (grep-mode)
      ;; Make this buffer current for next/previous-error
      (setq next-error-last-buffer buf)
      ;; Set up keymap before possible wgrep-setup, so that wgrep
      ;; restores our binding too when the user finishes editing.
      (use-local-map (make-composed-keymap
                      embark-consult-revert-map
                      (current-local-map)))
      (setq-local wgrep-header/footer-parser #'ignore)
      (when (fboundp 'wgrep-setup) (wgrep-setup)))
    (pop-to-buffer buf)))

(defun embark-consult-goto-grep (location)
  "Go to LOCATION, which should be a string with a grep match."
  ;; Actions are run in the target window, so in this case whatever
  ;; window was selected when the command that produced the
  ;; xref-location candidates ran.  In particular, we inherit the
  ;; default-directory of the buffer in that window, but we really
  ;; want the default-directory of the minibuffer or collect window we
  ;; call the action from, which is the previous window, since the
  ;; location is given relative to that directory.
  (let ((default-directory (with-selected-window (previous-window)
                             default-directory)))
    (consult--jump (consult--grep-position location))
    (pulse-momentary-highlight-one-line (point))))

(setf (alist-get 'consult-grep embark-default-action-overrides)
      #'embark-consult-goto-grep)
(setf (alist-get 'consult-grep embark-exporters-alist)
      #'embark-consult-export-grep)

;;; Support for consult-xref

(declare-function xref--show-xref-buffer "ext:xref")
(declare-function consult-xref "ext:consult-xref")
(defvar xref-auto-jump-to-first-xref)
(defvar consult-xref--fetcher)

(defun embark-consult-export-xref (items)
  "Create an xref buffer listing ITEMS."
  (cl-flet ((xref-items (items)
              (mapcar (lambda (item) (get-text-property 0 'consult-xref item))
                      items)))
    (let ((fetcher consult-xref--fetcher)
          (input (minibuffer-contents)))
      (set-buffer
       (xref--show-xref-buffer
        (lambda ()
          (let ((candidates (funcall fetcher)))
            (if (null (cdr candidates))
                candidates
              (catch 'xref-items
                (minibuffer-with-setup-hook
                    (lambda ()
                      (insert input)
                      (add-hook
                       'minibuffer-exit-hook
                       (lambda ()
                         (throw 'xref-items
                           (xref-items
                            (or
                             (plist-get
                              (embark--maybe-transform-candidates)
                              :candidates)
                             (user-error "No candidates for export")))))
                       nil t))
                  (consult-xref fetcher))))))
        `((fetched-xrefs . ,(xref-items items))
          (window . ,(embark--target-window))
          (auto-jump . ,xref-auto-jump-to-first-xref)
          (display-action)))))))

(setf (alist-get 'consult-xref embark-exporters-alist)
      #'embark-consult-export-xref)

;;; Support for consult-find and consult-locate

(setf (alist-get '(file . consult-find) embark-default-action-overrides)
      #'find-file)

(setf (alist-get '(file . consult-locate) embark-default-action-overrides)
      #'find-file)

;;; Support for consult-isearch

(setf (alist-get 'consult-isearch embark-transformer-alist)
      #'embark-consult--target-strip)

;;; Bindings for consult commands in embark keymaps

(define-key embark-file-map "x" #'consult-file-externally)

(define-key embark-become-file+buffer-map "Cb" #'consult-buffer)
(define-key embark-become-file+buffer-map "C4b" #'consult-buffer-other-window)

;;; Support for Consult search commands

(embark-define-keymap embark-consult-sync-search-map
  "Keymap for Consult sync search commands"
  :parent nil
  ("o" consult-outline)
  ("i" 'consult-imenu)
  ("I" 'consult-imenu-multi)
  ("l" consult-line)
  ("L" consult-line-multi))

(embark-define-keymap embark-consult-async-search-map
  "Keymap for Consult async search commands"
  :parent nil
  ("g" consult-grep)
  ("r" consult-ripgrep)
  ("G" consult-git-grep)
  ("f" consult-find)
  ("F" consult-locate))

(defvar embark-consult-search-map
  (keymap-canonicalize
   (make-composed-keymap embark-consult-sync-search-map
                         embark-consult-async-search-map))
  "Keymap for all Consult search commands.")

(fset 'embark-consult-sync-search-map embark-consult-sync-search-map)
(define-key embark-become-match-map "C" 'embark-consult-sync-search-map)

(cl-pushnew 'embark-consult-async-search-map embark-become-keymaps)

(fset 'embark-consult-search-map embark-consult-search-map)
(define-key embark-general-map "C" 'embark-consult-search-map)

(map-keymap
 (lambda (_key cmd)
   (cl-pushnew 'embark--allow-edit
               (alist-get cmd embark-target-injection-hooks)))
 embark-consult-search-map)

(defun embark-consult--unique-match (&rest _)
  "If there is a unique matching candidate, accept it.
This is intended to be used in `embark-target-injection-hooks'."
  (let ((candidates (cdr (embark-minibuffer-candidates))))
    (if (or (null candidates) (cdr candidates))
        (embark--allow-edit)
      (delete-minibuffer-contents)
      (insert (car candidates)))))

(dolist (cmd '(consult-outline consult-imenu consult-imenu-multi))
  (setf (alist-get cmd embark-target-injection-hooks)
        (remq 'embark--allow-edit
              (alist-get cmd embark-target-injection-hooks)))
  (cl-pushnew #'embark-consult--unique-match
              (alist-get cmd embark-target-injection-hooks)))

(cl-defun embark-consult--prep-async (&key type target &allow-other-keys)
  "Either add Consult's async separator or ignore the TARGET depending on TYPE.
If the TARGET of the given TYPE has an associated notion of
directory, we don't want to search for the text of target, but
rather just start a search in the associated directory.

This is intended to be used in `embark-target-injection-hooks'
for any action that is a Consult async command."
  (let* ((style (alist-get consult-async-split-style
                           consult-async-split-styles-alist))
         (initial (plist-get style :initial))
         (separator (plist-get style :separator))
         (directory (embark--associated-directory target type)))
    (when directory
      (delete-minibuffer-contents))
    (when initial
      (goto-char (minibuffer-prompt-end))
      (insert initial)
      (goto-char (point-max)))
    (when (and separator (null directory))
      (goto-char (point-max))
      (insert separator))))

(map-keymap
 (lambda (_key cmd)
   (cl-pushnew #'embark--cd (alist-get cmd embark-pre-action-hooks))
   (cl-pushnew #'embark-consult--prep-async
               (alist-get cmd embark-target-injection-hooks)))
 embark-consult-async-search-map)

;;; Tables of contents for buffers: imenu and outline candidate collectors

(defun embark-consult-outline-candidates ()
  "Collect all outline headings in the current buffer."
  (cons 'consult-location (consult--outline-candidates)))

(autoload 'consult-imenu--items "consult-imenu")

(defun embark-consult-imenu-candidates ()
  "Collect all imenu items in the current buffer."
  (cons 'imenu (mapcar #'car (consult-imenu--items))))

(declare-function consult-imenu--group "ext:consult-imenu")

(defun embark-consult--imenu-group-function (type prop)
  "Return a suitable group-function for imenu.
TYPE is the completion category.
PROP is the metadata property.
Meant as :after-until advice for `embark-collect--metadatum'."
  (when (and (eq type 'imenu) (eq prop 'group-function))
    (consult-imenu--group)))

(advice-add #'embark-collect--metadatum :after-until
            #'embark-consult--imenu-group-function)

(defun embark-consult-imenu-or-outline-candidates ()
  "Collect imenu items in prog modes buffer or outline headings otherwise."
  (if (derived-mode-p 'prog-mode)
      (embark-consult-imenu-candidates)
    (embark-consult-outline-candidates)))

(setf (alist-get 'imenu embark-default-action-overrides) 'consult-imenu)

(add-to-list 'embark-candidate-collectors
             #'embark-consult-imenu-or-outline-candidates
             'append)

(provide 'embark-consult)
;;; embark-consult.el ends here
