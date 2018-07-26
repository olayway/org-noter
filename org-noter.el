;;; org-noter.el --- A synchronized, Org-mode, document annotator       -*- lexical-binding: t; -*-

;; Copyright (C) 2017  Gonçalo Santos

;; Author: Gonçalo Santos (aka. weirdNox@GitHub)
;; Homepage: https://github.com/weirdNox/org-noter
;; Keywords: lisp pdf interleave annotate external sync notes documents org-mode
;; Package-Requires: ((emacs "24.4") (cl-lib "0.6") (org "9.0"))
;; Version: 1.1.1

;; This file is not part of GNU Emacs.

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

;; The idea is to let you create notes that are kept in sync when you scroll through the
;; document, but that are external to it - the notes themselves live in an Org-mode file. As
;; such, this leverages the power of Org-mode (the notes may have outlines, latex fragments,
;; babel, etc...) while acting like notes that are made /in/ the document.

;; Also, I must thank Sebastian for the original idea and inspiration!
;; Link to the original Interleave package:
;; https://github.com/rudolfochrist/interleave

;;; Code:
(require 'org)
(require 'org-element)
(require 'cl-lib)

(declare-function doc-view-goto-page "doc-view")
(declare-function image-display-size "image-mode")
(declare-function image-get-display-property "image-mode")
(declare-function image-mode-window-get "image-mode")
(declare-function image-scroll-up "image-mode")
(declare-function nov-render-document "ext:nov")
(declare-function pdf-info-getannots "ext:pdf-info")
(declare-function pdf-info-gettext "ext:pdf-info")
(declare-function pdf-info-outline "ext:pdf-info")
(declare-function pdf-info-pagelinks "ext:pdf-info")
(declare-function pdf-util-tooltip-arrow "ext:pdf-util")
(declare-function pdf-view-active-region "ext:pdf-view")
(declare-function pdf-view-active-region-p "ext:pdf-view")
(declare-function pdf-view-active-region-text "ext:pdf-view")
(declare-function pdf-view-goto-page "ext:pdf-view")
(declare-function pdf-view-mode "ext:pdf-view")
(defvar nov-documents-index)
(defvar nov-file-name)

;; --------------------------------------------------------------------------------
;; NOTE(nox): User variables
(defgroup org-noter nil
  "A synchronized, external annotator"
  :group 'convenience
  :version "25.3.1")

(defcustom org-noter-property-doc-file "NOTER_DOCUMENT"
  "Name of the property that specifies the document."
  :group 'org-noter
  :type 'string)

(defcustom org-noter-property-note-location "NOTER_PAGE"
  "Name of the property that specifies the location of the current note.
The default value is still NOTER_PAGE for backwards compatibility."
  :group 'org-noter
  :type 'string)

(defcustom org-noter-default-heading-title "Notes for page $p$"
  "The default title for headings created with `org-noter-insert-note'.
$p$ is replaced with the number of the page or chapter you are in
at the moment."
  :group 'org-noter
  :type 'string)

(defcustom org-noter-notes-window-behavior '(start scroll)
  "This setting specifies in what situations the notes window should be created.

When the list contains:
- `start', the window will be created when starting a `org-noter' session.
- `scroll', it will be created when you go to a location with an associated note."
  :group 'org-noter
  :type '(set (const :tag "Session start" start)
              (const :tag "Scrolling" scroll)))

(defcustom org-noter-notes-window-location 'horizontal-split
  "Whether the notes should appear in the main frame (horizontal or vertical split) or in a separate frame.

Note that this will only have effect on session startup if `start'
is member of `org-noter-notes-window-behavior' (which see)."
  :group 'org-noter
  :type '(choice (const :tag "Horizontal" horizontal-split)
                 (const :tag "Vertical" vertical-split)
                 (const :tag "Other frame" 'other-frame)))

(defcustom org-noter-auto-save-last-location nil
  "When non-nil, save the last visited location automatically; when starting a new session, go to that location."
  :group 'org-noter
  :type 'boolean)

(defcustom org-noter-hide-other nil
  "When non-nil, hide all headings not related to the command
  used, like notes from different locations when scrolling."
  :group 'org-noter
  :type 'boolean)

(defcustom org-noter-always-create-frame t
  "When non-nil, org-noter will always create a new frame for the session.
When nil, it will use the selected frame if it does not belong to any other session."
  :group 'org-noter
  :type 'boolean)

(defcustom org-noter-separate-notes-from-heading nil
  "When non-nil, add an empty line between each note's heading and content."
  :group 'org-noter
  :type 'boolean)

(defcustom org-noter-insert-selected-text-inside-note t
  "When non-nil, it will automatically append the selected text into an existing note."
  :group 'org-noter
  :type 'boolean)

(defcustom org-noter-closest-tipping-point 0.3
  "Defines when to show the closest previous note.

Let x be (this value)*100. The following schematic represents the
view (eg. a page of a PDF):

+----+
|    | -> If there are notes in here, the closest previous note is not shown
+----+--> Tipping point, at x% of the view
|    | -> When _all_ notes are in here, below the tipping point, the closest
|    |    previous note will be shown.
+----+

When this value is negative, disable this feature.

This setting may be changed document-by-document with the
function `org-noter-set-closest-tipping-point', which see."
  :group 'org-noter
  :type 'number)

(defcustom org-noter-default-notes-file-names '("Notes.org")
  "List of possible names for the default notes file, in increasing order of priority."
  :group 'org-noter
  :type 'list)

(defcustom org-noter-notes-search-path '("~/Documents")
  "List of paths to check (non recursively) when searching for a notes file."
  :group 'org-noter
  :type 'list)

(defcustom org-noter-arrow-delay 0.2
  "Number of seconds from when the command was invoked until the tooltip arrow appears.

When set to a negative number, the arrow tooltip is disabled.
This is needed in order to keep Emacs from hanging when doing many syncs."
  :group 'org-noter
  :type 'list)

(defface org-noter-no-notes-exist-face
  '((t
     :foreground "chocolate"
     :weight bold))
  "Face for modeline note count, when 0."
  :group 'org-noter)

(defface org-noter-notes-exist-face
  '((t
     :foreground "SpringGreen"
     :weight bold))
  "Face for modeline note count, when not 0."
  :group 'org-noter)

;; --------------------------------------------------------------------------------
;; NOTE(nox): Private variables or constants
(cl-defstruct org-noter--session
  frame doc-buffer notes-buffer ast modified-tick doc-mode display-name notes-file-path property-text
  level num-notes-in-view window-behavior window-location auto-save-last-location hide-other
  closest-tipping-point)

(defvar org-noter--sessions nil
  "List of `org-noter' sessions.")

(defvar-local org-noter--session nil
  "Session associated with the current buffer.")

(defvar org-noter--inhibit-location-change-handler nil
  "Prevent location change from updating point in notes.")

(defvar org-noter--start-location-override nil
  "Used to open the session from the document in the right page.")

(defvar-local org-noter--nov-timer nil
  "Timer for synchronizing notes after scrolling.")

(defvar org-noter--arrow-location nil
  "A vector [TIMER WINDOW TOP] that shows where the arrow should appear, when idling.")

(defconst org-noter--property-behavior "NOTER_NOTES_BEHAVIOR"
  "Property for overriding global `org-noter-notes-window-behavior'.")

(defconst org-noter--property-location "NOTER_NOTES_LOCATION"
  "Property for overriding global `org-noter-notes-window-location'.")

(defconst org-noter--property-auto-save-last-location "NOTER_AUTO_SAVE_LAST_LOCATION"
  "Property for overriding global `org-noter-auto-save-last-location'.")

(defconst org-noter--property-hide-other "NOTER_HIDE_OTHER"
  "Property for overriding global `org-noter-hide-other'.")

(defconst org-noter--property-closest-tipping-point "NOTER_CLOSEST_TIPPING_POINT"
  "Property for overriding global `org-noter-closest-tipping-point'.")

(defconst org-noter--note-search-no-recurse (delete 'headline (append org-element-all-elements nil))
  "List of elements that shouldn't be recursed into when searching for notes.")

;; --------------------------------------------------------------------------------
;; NOTE(nox): Utility functions
(defun org-noter--create-session (ast document-property-value notes-file-path)
  (let* ((raw-value-not-empty (> (length (org-element-property :raw-value ast)) 0))
         (display-name (if raw-value-not-empty
                           (org-element-property :raw-value ast)
                         (file-name-nondirectory document-property-value)))
         (frame-name (format "Emacs Org-noter - %s" display-name))

         (document (find-file-noselect document-property-value))
         (document-path (expand-file-name document-property-value))
         (document-major-mode (buffer-local-value 'major-mode document))
         (document-buffer-name
          (generate-new-buffer-name (concat (unless raw-value-not-empty "Org-noter: ") display-name)))
         (document-buffer
          (if (eq document-major-mode 'nov-mode)
              document
            (make-indirect-buffer document document-buffer-name t)))

         (notes-buffer
          (make-indirect-buffer
           (or (buffer-base-buffer) (current-buffer))
           (generate-new-buffer-name (concat "Notes of " display-name)) t))

         (session
          (make-org-noter--session
           :display-name display-name
           :frame
           (if (or org-noter-always-create-frame
                   (catch 'has-session
                     (dolist (test-session org-noter--sessions)
                       (when (eq (org-noter--session-frame test-session) (selected-frame))
                         (throw 'has-session t)))))
               (make-frame `((name . ,frame-name) (fullscreen . maximized)))
             (set-frame-parameter nil 'name frame-name)
             (selected-frame))
           :doc-mode document-major-mode
           :property-text document-property-value
           :notes-file-path notes-file-path
           :doc-buffer document-buffer
           :notes-buffer notes-buffer
           :level (org-element-property :level ast)
           :window-behavior (or (org-noter--notes-window-behavior-property ast) org-noter-notes-window-behavior)
           :window-location (or (org-noter--notes-window-location-property ast) org-noter-notes-window-location)
           :auto-save-last-location (or (org-noter--auto-save-location-property ast)
                                        org-noter-auto-save-last-location)
           :hide-other (or (org-noter--hide-other-property ast) org-noter-hide-other)
           :closest-tipping-point (or (org-noter--closest-tipping-point-property ast)
                                      org-noter-closest-tipping-point)
           :modified-tick -1))

         (target-location org-noter--start-location-override))

    (add-hook 'delete-frame-functions 'org-noter--handle-delete-frame)
    (push session org-noter--sessions)

    (with-current-buffer document-buffer
      (cond
       ;; NOTE(nox): PDF Tools
       ((eq document-major-mode 'pdf-view-mode)
        (setq buffer-file-name document-path)
        (pdf-view-mode)
        (add-hook 'pdf-view-after-change-page-hook 'org-noter--doc-location-change-handler nil t))

       ;; NOTE(nox): DocView
       ((eq document-major-mode 'doc-view-mode)
        (setq buffer-file-name document-path)
        (doc-view-mode)
        (advice-add 'doc-view-goto-page :after 'org-noter--location-change-advice))

       ;; NOTE(nox): Nov.el
       ((eq document-major-mode 'nov-mode)
        (rename-buffer document-buffer-name)
        (advice-add 'nov-render-document :after 'org-noter--nov-scroll-handler)
        (add-hook 'window-scroll-functions 'org-noter--nov-scroll-handler nil t))

       (t (error "This document handler is not supported :/")))

      (org-noter-doc-mode 1)
      (setq org-noter--session session)
      (add-hook 'kill-buffer-hook 'org-noter--handle-kill-buffer nil t))

    (with-current-buffer notes-buffer
      (org-noter-notes-mode 1)
      (setq buffer-file-name notes-file-path
            org-noter--session session
            fringe-indicator-alist '((truncation . nil)))
      (add-hook 'kill-buffer-hook 'org-noter--handle-kill-buffer nil t)
      (add-hook 'window-scroll-functions 'org-noter--set-notes-scroll nil t)
      (org-noter--set-read-only (org-noter--parse-root))
      (unless target-location
        (setq target-location (org-noter--location-property (org-noter--get-containing-heading t)))))

    (org-noter--setup-windows session)

    ;; NOTE(nox): This timer is for preventing reflowing too soon.
    (run-with-idle-timer
     0.05 nil
     (lambda ()
       (with-current-buffer document-buffer
         (let ((org-noter--inhibit-location-change-handler t))
           (when target-location (org-noter--doc-goto-location target-location)))
         (org-noter--doc-location-change-handler))))))

(defun org-noter--valid-session (session)
  (when session
    (if (and (frame-live-p (org-noter--session-frame session))
             (buffer-live-p (org-noter--session-doc-buffer session))
             (buffer-live-p (org-noter--session-notes-buffer session)))
        t
      (org-noter-kill-session session)
      nil)))

(defmacro org-noter--with-valid-session (&rest body)
  `(let ((session org-noter--session))
     (when (org-noter--valid-session session)
       (progn ,@body))))

(defun org-noter--handle-kill-buffer ()
  (org-noter--with-valid-session
   (let ((buffer (current-buffer))
         (notes-buffer (org-noter--session-notes-buffer session))
         (doc-buffer (org-noter--session-doc-buffer session)))
     ;; NOTE(nox): This needs to be checked in order to prevent session killing because of
     ;; temporary buffers with the same local variables
     (when (or (eq buffer notes-buffer)
               (eq buffer doc-buffer))
       (org-noter-kill-session session)))))

(defun org-noter--handle-delete-frame (frame)
  (dolist (session org-noter--sessions)
    (when (eq (org-noter--session-frame session) frame)
      (org-noter-kill-session session))))

(defun org-noter--parse-root (&optional buffer property-doc-path)
  (let* ((session (when (org-noter--valid-session org-noter--session) org-noter--session))
         (use-args (and (stringp property-doc-path) (buffer-live-p buffer)
                        (eq (buffer-local-value 'major-mode buffer) 'org-mode)))
         (notes-buffer (when use-args buffer))
         (wanted-prop (when use-args property-doc-path))
         ast)
    ;; NOTE(nox): Try to use a cached AST
    (when (and (not use-args) session)
      (setq notes-buffer (org-noter--session-notes-buffer session)
            wanted-prop (org-noter--session-property-text session))
      (when (= (buffer-chars-modified-tick (org-noter--session-notes-buffer session))
               (org-noter--session-modified-tick session))
        (setq ast (org-noter--session-ast session))))

    (when (and (not ast) (buffer-live-p notes-buffer))
      (with-current-buffer notes-buffer
        (org-with-wide-buffer
         (when
             (or
              ;; NOTE(nox): Start by trying to find a parent heading with the specified
              ;; property
              (catch 'break
                (while t
                  (when (string= wanted-prop
                                 (org-entry-get nil org-noter-property-doc-file))
                    (org-back-to-heading t)
                    (throw 'break t))
                  (unless (org-up-heading-safe) (throw 'break nil))))
              ;; NOTE(nox): Could not find parent with property, do a global search
              (let ((pos (org-find-property org-noter-property-doc-file wanted-prop)))
                (when pos (goto-char pos))))
           (org-narrow-to-subtree)
           (setq ast (car (org-element-contents (org-element-parse-buffer 'greater-element))))
           (when session
             (setf (org-noter--session-ast session) ast
                   (org-noter--session-modified-tick session) (buffer-chars-modified-tick)))))))
    ast))

(defun org-noter--get-properties-end (ast &optional force-trim)
  (when ast
    (let* ((contents (org-element-contents ast))
           (section (org-element-map contents 'section 'identity nil t 'headline))
           (properties (org-element-map section 'property-drawer 'identity nil t))
           properties-end)
      (if (not properties)
          (org-element-property :contents-begin ast)
        (setq properties-end (org-element-property :end properties))
        (when (or force-trim
                  (= (org-element-property :end section) properties-end))
          (while (not (eq (char-before properties-end) ?:))
            (setq properties-end (1- properties-end))))
        properties-end))))

(defun org-noter--set-read-only (ast)
  (org-with-wide-buffer
   (when ast
     (let* ((level (org-element-property :level ast))
            (begin (org-element-property :begin ast))
            (title-begin (+ 1 level begin))
            (contents-begin (org-element-property :contents-begin ast))
            (properties-end (org-noter--get-properties-end ast t))
            (inhibit-read-only t)
            (modified (buffer-modified-p)))
       (add-text-properties (max 1 (1- begin)) begin '(read-only t))
       (add-text-properties begin (1- title-begin) '(read-only t front-sticky t))
       (add-text-properties (1- title-begin) title-begin '(read-only t rear-nonsticky t))
       (add-text-properties (1- contents-begin) (1- properties-end) '(read-only t))
       (add-text-properties (1- properties-end) properties-end
                            '(read-only t rear-nonsticky t))
       (set-buffer-modified-p modified)))))

(defun org-noter--unset-read-only (ast)
  (org-with-wide-buffer
   (when ast
     (let ((begin (org-element-property :begin ast))
           (end (org-noter--get-properties-end ast t))
           (inhibit-read-only t)
           (modified (buffer-modified-p)))
       (remove-list-of-text-properties (max 1 (1- begin)) end
                                       '(read-only front-sticky rear-nonsticky))
       (set-buffer-modified-p modified)))))

(defun org-noter--set-notes-scroll (window &rest ignored)
  (when window
    (with-selected-window window
      (org-noter--with-valid-session
       (let* ((level (org-noter--session-level session))
              (goal (* (1- level) 2))
              (current-scroll (window-hscroll)))
         (when (and (bound-and-true-p org-indent-mode) (< current-scroll goal))
           (scroll-right current-scroll)
           (scroll-left goal t)))))))

(defun org-noter--insert-heading (level title &optional newlines-number)
  "Insert a new heading at LEVEL with TITLE.
The point will be at the start of the contents, after any
properties, by a margin of NEWLINES-NUMBER."
  (org-insert-heading)
  (let* ((initial-level (org-element-property :level (org-element-at-point)))
         (changer (if (> level initial-level) 'org-do-demote 'org-do-promote))
         (number-of-times (abs (- level initial-level))))
    (dotimes (_ number-of-times)
      (funcall changer))

    (insert title)

    (org-end-of-subtree)
    (while (= 32 (char-syntax (char-before))) (backward-char))

    (dotimes (_ (or newlines-number 1))
      (if (and (not (eobp)) (org-next-line-empty-p))
          (forward-line)
        (insert "\n")))))

(defun org-noter--narrow-to-root (ast)
  (when ast
    (save-excursion
      (goto-char (org-element-property :begin ast))
      (org-show-entry)
      (org-narrow-to-subtree)
      (org-show-children)
      (org-cycle-hide-drawers 'all))))

(defun org-noter--get-doc-window ()
  (org-noter--with-valid-session
   (or (get-buffer-window (org-noter--session-doc-buffer session)
                          (org-noter--session-frame session))
       (org-noter--setup-windows org-noter--session)
       (get-buffer-window (org-noter--session-doc-buffer session)
                          (org-noter--session-frame session)))))

(defun org-noter--get-notes-window (&optional type)
  (org-noter--with-valid-session
   (let ((notes-buffer (org-noter--session-notes-buffer session))
         (window-location (org-noter--session-window-location session))
         (window-behavior (org-noter--session-window-behavior session))
         notes-window)
     (or (get-buffer-window notes-buffer t)
         (when (or (eq type 'force) (memq type window-behavior))
           (if (eq window-location 'other-frame)
               (let ((restore-frame (selected-frame)))
                 (switch-to-buffer-other-frame notes-buffer)
                 (setq notes-window (get-buffer-window notes-buffer t))
                 (x-focus-frame restore-frame)
                 (raise-frame (window-frame notes-window)))

             (with-selected-window (org-noter--get-doc-window)
               (let ((horizontal (eq window-location 'horizontal-split)))
                 (setq
                  notes-window
                  (if (window-combined-p nil horizontal)
                      ;; NOTE(nox): Reuse already existent window
                      (or (window-next-sibling) (window-prev-sibling))

                    (if horizontal
                        (split-window-right)
                      (split-window-below))))))

             (set-window-buffer notes-window notes-buffer))
           notes-window)))))

(defun org-noter--setup-windows (session)
  "Setup windows when starting session, respecting user configuration."
  (when (org-noter--valid-session session)
    (with-selected-frame (org-noter--session-frame session)
      (delete-other-windows)
      (let* ((doc-buffer (org-noter--session-doc-buffer session))
             (doc-window (selected-window))
             (notes-buffer (org-noter--session-notes-buffer session))
             notes-window)

        (set-window-buffer doc-window doc-buffer)
        (set-window-dedicated-p doc-window t)

        (with-current-buffer notes-buffer
          (org-noter--narrow-to-root
           (org-noter--parse-root notes-buffer (org-noter--session-property-text session)))
          (setq notes-window (org-noter--get-notes-window 'start))
          (org-noter--set-notes-scroll notes-window))))))

(defmacro org-noter--with-selected-notes-window (error-str &rest body)
  (let ((with-error (stringp error-str)))
    `(org-noter--with-valid-session
      (let ((notes-window (org-noter--get-notes-window)))
        (if notes-window
            (with-selected-window notes-window
              ,(if with-error
                   `(progn ,@body)
                 (if body
                     `(progn ,error-str ,@body)
                   `(progn ,error-str))))
          ,(when with-error `(user-error "%s" ,error-str)))))))

(defun org-noter--notes-window-behavior-property (ast)
  (let ((property (org-element-property (intern (concat ":" org-noter--property-behavior)) ast))
        value)
    (when (and (stringp property) (> (length property) 0))
      (setq value (car (read-from-string property)))
      (when (listp value)
        value))))

(defun org-noter--notes-window-location-property (ast)
  (let ((property (org-element-property (intern (concat ":" org-noter--property-location)) ast))
        value)
    (when (and (stringp property) (> (length property) 0))
      (setq value (intern property))
      (when (memq value '(horizontal-split vertical-split other-frame))
        value))))

(defun org-noter--auto-save-location-property (ast)
  (let ((property (org-element-property (intern (concat ":" org-noter--property-auto-save-last-location)) ast)))
    (when (and (stringp property) (> (length property) 0))
      (when (intern property) t))))

(defun org-noter--hide-other-property (ast)
  (let ((property (org-element-property (intern (concat ":" org-noter--property-hide-other)) ast)))
    (when (and (stringp property) (> (length property) 0))
      (when (intern property) t))))

(defun org-noter--closest-tipping-point-property (ast)
  (let ((property (org-element-property (intern (concat ":" org-noter--property-closest-tipping-point)) ast)))
    (when (and (stringp property) (> (length property) 0))
      (ignore-errors (string-to-number property)))))

(defun org-noter--doc-approx-location (&optional precise-location)
  (let ((window (if (org-noter--valid-session org-noter--session)
                    (org-noter--get-doc-window)
                  (selected-window))))
    (cl-assert window)
    (with-selected-window window
      (cond
       ((memq major-mode '(doc-view-mode pdf-view-mode))
        (cons (image-mode-window-get 'page)
              (if (numberp precise-location) precise-location 0)))

       ((eq major-mode 'nov-mode)
        (cons nov-documents-index
              (cond
               ((numberp precise-location) precise-location)
               ((eq precise-location 'infer) (/ (+ (window-start) (window-end nil t)) 2))
               (t 1))))))))

(defun org-noter--location-change-advice (&rest _)
  (org-noter--with-valid-session (org-noter--doc-location-change-handler)))

(defun org-noter--nov-scroll-handler (&rest _)
  (when org-noter--nov-timer (cancel-timer org-noter--nov-timer))
  (unless org-noter--inhibit-location-change-handler
    (setq org-noter--nov-timer (run-with-timer 0.25 nil 'org-noter--doc-location-change-handler))))

(defun org-noter--location-property (arg)
  (let* ((property
          (if (stringp arg) arg
            (org-element-property (intern (concat ":" org-noter-property-note-location)) arg)))
         value)
    (when (and (stringp property) (> (length property) 0))
      (setq value (car (read-from-string property)))
      (cond ((and (consp value) (integerp (car value)) (numberp (cdr value))) value)
            ((integerp value) (cons value 0))
            (t nil)))))

(defun org-noter--pretty-print-location (location-cons)
  (org-noter--with-valid-session
   (let ((to-print
          (cond
           ((memq (org-noter--session-doc-mode session) '(doc-view-mode pdf-view-mode))
            (if (or (not (cdr location-cons)) (<= (cdr location-cons) 0))
                (car location-cons)
              location-cons))
           ((eq (org-noter--session-doc-mode session) 'nov-mode)
            (if (or (not (cdr location-cons)) (<= (cdr location-cons) 1))
                (car location-cons)
              location-cons)))))
     (format "%s" to-print))))

(defun org-noter--get-containing-heading (&optional include-root)
  "Get smallest containing heading that encloses the point and has location property.
If the point isn't inside any heading with location property, return the outer heading."
  (org-noter--with-valid-session
   (unless (org-before-first-heading-p)
     (org-with-wide-buffer
      (org-back-to-heading)
      (let ((root-doc-prop (org-noter--session-property-text session))
            previous)
        (catch 'break
          (while t
            (let ((prop (org-noter--location-property
                         (org-entry-get nil org-noter-property-note-location)))
                  (at-root (string= (org-entry-get nil org-noter-property-doc-file)
                                    root-doc-prop))
                  (heading (org-element-at-point)))
              (when (and prop (or include-root (not at-root)))
                (throw 'break heading))

              (when (or at-root (not (org-up-heading-safe)))
                (throw 'break (if include-root heading previous)))

              (setq previous heading)))))))))

(defun org-noter--doc-get-page-slice ()
  "Return (slice-top . slice-height)."
  (let* ((slice (or (image-mode-window-get 'slice) '(0 0 1 1)))
         (slice-top (float (nth 1 slice)))
         (slice-height (float (nth 3 slice))))
    (when (or (> slice-top 1)
              (> slice-height 1))
      (let ((height (cdr (image-size (image-mode-window-get 'image) t))))
        (setq slice-top (/ slice-top height)
              slice-height (/ slice-height height))))
    (cons slice-top slice-height)))

(defun org-noter--conv-page-scroll-percentage (scroll)
  (let* ((slice (org-noter--doc-get-page-slice))
         (display-height (cdr (image-display-size (image-get-display-property))))
         (display-percentage (/ scroll display-height))
         (percentage (+ (car slice) (* (cdr slice) display-percentage))))
    (max 0 (min 1 percentage))))

(defun org-noter--conv-page-percentage-scroll (percentage)
  (let* ((slice (org-noter--doc-get-page-slice))
         (display-height (cdr (image-display-size (image-get-display-property))))
         (display-percentage (min 1 (max 0 (/ (- percentage (car slice)) (cdr slice)))))
         (scroll (max 0 (floor (* display-percentage display-height)))))
    scroll))

(defun org-noter--ask-precise-location ()
  (org-noter--with-valid-session
   (let ((window (org-noter--get-doc-window))
         event)
     (with-selected-window window
       (while (not (and (eq 'mouse-1 (car event))
                        (eq window (posn-window (event-start event)))))
         (setq event (read-event "Click where you want the start of the note to be!")))

       (cond
        ((memq (org-noter--session-doc-mode session) '(doc-view-mode pdf-view-mode))
         (org-noter--conv-page-scroll-percentage (+ (window-vscroll)
                                                    (cdr (posn-col-row (event-start event))))))

        ((eq (org-noter--session-doc-mode session) 'nov-mode)
         (posn-point (event-start event))))))))

(defun org-noter--show-arrow ()
  (when (and org-noter--arrow-location
             (window-live-p (aref org-noter--arrow-location 1)))
    (with-selected-window (aref org-noter--arrow-location 1)
      (pdf-util-tooltip-arrow (aref org-noter--arrow-location 2))))
  (setq org-noter--arrow-location nil))

(defun org-noter--doc-goto-location (location-cons)
  "Go to location specified by LOCATION-CONS."
  (org-noter--with-valid-session
   (let ((window (org-noter--get-doc-window))
         (mode (org-noter--session-doc-mode session)))
     (with-selected-window window
       (cond
        ((memq mode '(doc-view-mode pdf-view-mode))
         (if (eq mode 'doc-view-mode)
             (doc-view-goto-page (car location-cons))
           (pdf-view-goto-page (car location-cons))
           ;; NOTE(nox): This timer is needed because the tooltip may introduce a delay,
           ;; so syncing multiple pages was slow
           (when (>= org-noter-arrow-delay 0)
             (when org-noter--arrow-location (cancel-timer (aref org-noter--arrow-location 0)))
             (setq org-noter--arrow-location
                   (vector (run-with-idle-timer org-noter-arrow-delay nil 'org-noter--show-arrow)
                           window
                           (cdr location-cons)))))
         (image-scroll-up (- (org-noter--conv-page-percentage-scroll (cdr location-cons))
                             (window-vscroll))))

        ((eq mode 'nov-mode)
         (setq nov-documents-index (car location-cons))
         (nov-render-document)
         (goto-char (cdr location-cons))
         (recenter)))
       ;; NOTE(nox): This needs to be here, because it would be issued anyway after
       ;; everything and would run org-noter--nov-scroll-handler.
       (redisplay)))))

(defun org-noter--compare-location-cons (comp p1 p2)
  "Compare P1 and P2, which are location cons.
When COMP is '<, '<=, '>, or '>=, it works as expected.
When COMP is '>f, it will return t when P1 is a page greater than
P2 or, when in the same page, if P1 is the _f_irst of the two."
  (cond ((not p1) nil)
        ((not p2) t)
        ((eq comp '=)
         (and (= (car p1) (car p2))
              (= (cdr p1) (cdr p2))))
        ((eq comp '<)
         (or (< (car p1) (car p2))
             (and (= (car p1) (car p2))
                  (< (cdr p1) (cdr p2)))))
        ((eq comp '<=)
         (or (< (car p1) (car p2))
             (and (=  (car p1) (car p2))
                  (<= (cdr p1) (cdr p2)))))
        ((eq comp '>)
         (or (> (car p1) (car p2))
             (and (= (car p1) (car p2))
                  (> (cdr p1) (cdr p2)))))
        ((eq comp '>=)
         (or (> (car p1) (car p2))
             (and (= (car p1) (car p2))
                  (>= (cdr p1) (cdr p2)))))
        ((eq comp '>f)
         (or (> (car p1) (car p2))
             (and (= (car p1) (car p2))
                  (< (cdr p1) (cdr p2)))))))

(defun org-noter--show-note-entry (note)
  "This will show the note entry and its children.
Every direct subheading that isn't a note itself will also be opened."
  (save-excursion
    (goto-char (org-element-property :begin note))
    (org-show-entry)
    (org-show-children)
    (org-show-set-visibility t)
    (org-element-map (org-element-contents note) 'headline
      (lambda (headline)
        (unless (org-noter--location-property headline)
          (goto-char (org-element-property :begin headline))
          (org-show-entry)
          (org-show-children)))
      nil nil org-element-all-elements)))

(defun org-noter--focus-notes-region (view-info)
  (org-noter--with-selected-notes-window
   (when (org-noter--session-hide-other session) (org-overview))
   (org-cycle-hide-drawers 'all)

   (let ((notes-cons (org-noter--view-info-notes view-info)))
     (cond
      (notes-cons
       (dolist (note-cons notes-cons) (org-noter--show-note-entry (car note-cons)))

       (unless (catch 'break
                 (let ((point (point)))
                   (dolist (region (org-noter--view-info-regions view-info))
                     (when (and (>= point (car region))
                                (<  point (cdr region)))
                       (throw 'break t)))))
         (let* ((region (car (org-noter--view-info-regions view-info)))
                (begin (car region))
                (end   (cdr region))
                (target (org-noter--get-properties-end (caar notes-cons)))
                (window-start (window-start))
                (window-end (window-end nil t))
                (num-lines (count-screen-lines begin end)))
           (cond
            ((> num-lines (window-height))
             (goto-char begin)
             (recenter 0))

            ((< begin window-start)
             (goto-char begin)
             (recenter 0))

            ((> end window-end)
             (goto-char end)
             (recenter -2)))

           (goto-char target))))

      (t
       (org-noter--show-note-entry (org-noter--parse-root)))))))

(defun org-noter--get-current-view ()
  "Return a vector with the current view information."
  (org-noter--with-valid-session
   (let ((mode (org-noter--session-doc-mode session)))
     (cond ((memq mode '(doc-view-mode pdf-view-mode))
            (vector 'paged (car (org-noter--doc-approx-location))))
           ((eq mode 'nov-mode)
            (with-selected-window (org-noter--get-doc-window)
              (vector 'nov (org-noter--doc-approx-location (window-start))
                      (org-noter--doc-approx-location (window-end nil t)))))
           (t (error "Unknown document type"))))))

(defun org-noter--note-after-tipping-point (point note-property view)
  ;; NOTE(nox): This __assumes__ the note is inside the view!
  (cond
   ((eq (aref view 0) 'paged)
    (> (cdr note-property) point))
   ((eq (aref view 0) 'nov)
    (> (cdr note-property) (+ (aref view 1) (* point (- (aref view 2) (aref view 1))))))))

(defun org-noter--relative-position-to-view (note-property view)
  (cond
   ((eq (aref view 0) 'paged)
    (let ((note-page (car note-property))
          (view-page (aref view 1)))
      (cond ((< note-page view-page) 'before)
            ((= note-page view-page) 'inside)
            (t                       'after))))
   ((eq (aref view 0) 'nov)
    (let ((view-top (aref view 1))
          (view-bot (aref view 2)))
      (cond ((org-noter--compare-location-cons '<  note-property view-top) 'before)
            ((org-noter--compare-location-cons '<= note-property view-bot) 'inside)
            (t                                                             'after))))))

(defmacro org-noter--view-region-finish (info &optional terminating-headline)
  `(when ,info
     ,(if terminating-headline
          `(push (cons (aref ,info 1) (min (aref ,info 2) (org-element-property :begin ,terminating-headline)))
                 (gv-deref (aref ,info 0)))
        `(push (cons (aref ,info 1) (aref ,info 2)) (gv-deref (aref ,info 0))))
     (setq ,info nil)))

(defmacro org-noter--view-region-add (info list-name headline)
  `(progn
     (when (and ,info (not (eq (aref ,info 0) ,list-name))) (org-noter--view-region-finish ,info ,headline))

     (if ,info
         (setf (aref ,info 2) (max (aref ,info 2) (org-element-property :end ,headline)))
       (setq ,info (vector (gv-ref ,list-name)
                           (org-element-property :begin ,headline) (org-element-property :end ,headline)
                           ',list-name)))))

(cl-defstruct org-noter--view-info notes regions reference-for-insertion)

(defun org-noter--get-view-info (view &optional new-location)
  "Return VIEW related information.

When optional NEW-LOCATION is provided, it will be used to find
the best heading to serve as a reference to create the new one
relative to."
  (when view
    (org-noter--with-valid-session
     (let ((contents (org-element-contents (org-noter--parse-root)))
           (without-property t) (search-for-before t) ;; NOTE(nox): Used when searching reference
           notes-in-view regions-in-view
           reference-for-insertion reference-location
           (all-after-tipping-point t)
           (closest-tipping-point (and (>= (org-noter--session-closest-tipping-point session) 0)
                                       (org-noter--session-closest-tipping-point session)))
           closest-notes closest-notes-regions closest-notes-location
           current-region-info) ;; NOTE(nox): [REGIONS-LIST-PTR START MAX-END REGIONS-LIST-NAME]

       (org-element-map contents 'headline
         (lambda (headline)
           (let ((property (org-noter--location-property headline)))
             (cond
              (property
               (let ((relative-position (org-noter--relative-position-to-view property view)))
                 (cond
                  ((eq relative-position 'inside)
                   (push (cons headline headline) notes-in-view)

                   (org-noter--view-region-add current-region-info regions-in-view headline)

                   (setq all-after-tipping-point
                         (and all-after-tipping-point (org-noter--note-after-tipping-point
                                                       closest-tipping-point property view))))

                  (t
                   (when (and current-region-info (eq (aref current-region-info 3) 'regions-in-view))
                     (org-noter--view-region-finish current-region-info headline))

                   (when (and closest-tipping-point all-after-tipping-point)
                     (cond
                      ((and (eq relative-position 'before)
                            (org-noter--compare-location-cons '> property closest-notes-location))
                       (setq closest-notes (list (cons headline headline))
                             closest-notes-location property
                             current-region-info nil
                             closest-notes-regions nil)
                       (org-noter--view-region-add current-region-info closest-notes-regions headline))

                      ((and (eq relative-position 'before) (equal property closest-notes-location))
                       (push (cons headline headline) closest-notes)
                       (org-noter--view-region-add current-region-info closest-notes-regions headline))

                      (t (org-noter--view-region-finish current-region-info headline)))))))

               (when new-location
                 (setq without-property nil)
                 (cond ((and (org-noter--compare-location-cons '<= property new-location)
                             (org-noter--compare-location-cons '>= property reference-location))
                        (setq search-for-before nil
                              reference-for-insertion (cons 'after headline)
                              reference-location property))

                       ((and search-for-before
                             (org-noter--compare-location-cons '>= property new-location)
                             (org-noter--compare-location-cons '<= property reference-location))
                        (setq reference-for-insertion (cons 'before headline)
                              reference-location property)))))

              (t
               (when current-region-info
                 (cond ((eq (aref current-region-info 3) 'regions-in-view)
                        (when (< (org-element-property :begin headline)
                                 (org-element-property :end   (caar notes-in-view)))
                          (setcdr (car notes-in-view) headline)))
                       ((eq (aref current-region-info 3) 'closest-notes-regions)
                        (when (< (org-element-property :begin headline)
                                 (org-element-property :end   (caar closest-notes)))
                          (setcdr (car closest-notes) headline)))))

               (when (and new-location without-property)
                 (setq reference-for-insertion (cons 'after headline)))))))
         nil nil org-noter--note-search-no-recurse)

       (org-noter--view-region-finish current-region-info)

       (setf (org-noter--session-num-notes-in-view session) (length notes-in-view))

       (when all-after-tipping-point
         (setq notes-in-view   (append closest-notes         notes-in-view)
               regions-in-view (append closest-notes-regions regions-in-view)))

       (make-org-noter--view-info
        :notes (nreverse notes-in-view)
        :regions (nreverse regions-in-view)
        :reference-for-insertion reference-for-insertion)))))

(defun org-noter--make-view-info-for-single-note (headline)
  (let ((element-with-property (org-element-map (org-element-contents headline) 'headline
                                 (lambda (headline) (when (org-noter--location-property headline) headline))
                                 nil t))
        search-in last-element-inside-note)

    (when element-with-property
      (setq search-in (org-element-property :parent element-with-property))

      (org-element-map (org-element-contents search-in) '(section headline)
        (lambda (element) (if (org-noter--location-property element) t (setq last-element-inside-note element) nil))
        nil t org-element-all-elements))

    (make-org-noter--view-info
     :notes (list (cons headline headline))
     :regions (list (cons (org-element-property :begin headline)
                          (org-element-property :end (or last-element-inside-note headline)))))))

(defun org-noter--doc-location-change-handler ()
  (org-noter--with-valid-session
   (let ((view-info (org-noter--get-view-info (org-noter--get-current-view))))
     (force-mode-line-update t)
     (unless org-noter--inhibit-location-change-handler
       (org-noter--get-notes-window 'scroll)
       (org-noter--focus-notes-region view-info)))

   (when (org-noter--session-auto-save-last-location session) (org-noter-set-start-location))))

(defun org-noter--mode-line-text ()
  (org-noter--with-valid-session
   (let* ((number-of-notes (or (org-noter--session-num-notes-in-view session) 0)))
     (cond ((= number-of-notes 0) (propertize " 0 notes " 'face 'org-noter-no-notes-exist-face))
           ((= number-of-notes 1) (propertize " 1 note " 'face 'org-noter-notes-exist-face))
           (t (propertize (format " %d notes " number-of-notes) 'face 'org-noter-notes-exist-face))))))

;; NOTE(nox): From machc/pdf-tools-org
(defun org-noter--pdf-tools-edges-to-region (edges)
  "Get 4-entry region (LEFT TOP RIGHT BOTTOM) from several EDGES."
  (when edges
    (let ((left0 (nth 0 (car edges)))
          (top0 (nth 1 (car edges)))
          (bottom0 (nth 3 (car edges)))
          (top1 (nth 1 (car (last edges))))
          (right1 (nth 2 (car (last edges))))
          (bottom1 (nth 3 (car (last edges)))))
      (list left0
            (+ top0 (/ (- bottom0 top0) 3))
            right1
            (- bottom1 (/ (- bottom1 top1) 3))))))

(defun org-noter--check-if-document-is-annotated-on-file (document-path notes-path)
  ;; NOTE(nox): In order to insert the correct file contents
  (let ((buffer (find-buffer-visiting notes-path)))
    (when buffer (with-current-buffer buffer (save-buffer)))

    (with-temp-buffer
      (insert-file-contents notes-path)
      (catch 'break
        (while (re-search-forward (org-re-property org-noter-property-doc-file) nil t)
          (when (file-equal-p (expand-file-name (match-string 3) (file-name-directory notes-path))
                              document-path)
            ;; NOTE(nox): This notes file has the document we want!
            (throw 'break t)))))))

;; --------------------------------------------------------------------------------
;; NOTE(nox): User commands
(defun org-noter-set-start-location (&optional arg)
  "When opening a session with this document, go to the current location.
With a prefix ARG, remove start location."
  (interactive "P")
  (org-noter--with-valid-session
   (let ((inhibit-read-only t)
         (ast (org-noter--parse-root))
         (location-cons (org-noter--doc-approx-location 'infer)))
     (with-current-buffer (org-noter--session-notes-buffer session)
       (org-with-wide-buffer
        (goto-char (org-element-property :begin ast))
        (if arg
            (org-entry-delete nil org-noter-property-note-location)
          (org-entry-put nil org-noter-property-note-location
                         (org-noter--pretty-print-location location-cons))))))))

(defun org-noter-set-auto-save-last-location (arg)
  "This toggles saving the last visited location for this document.
With a prefix ARG, delete the current setting and use the default."
  (interactive "P")
  (org-noter--with-valid-session
   (let ((inhibit-read-only t)
         (ast (org-noter--parse-root))
         (new-setting (if arg
                          org-noter-auto-save-last-location
                        (not (org-noter--session-auto-save-last-location session)))))
     (setf (org-noter--session-auto-save-last-location session)
           new-setting)
     (with-current-buffer (org-noter--session-notes-buffer session)
       (org-with-wide-buffer
        (goto-char (org-element-property :begin ast))
        (if arg
            (org-entry-delete nil org-noter--property-auto-save-last-location)
          (org-entry-put nil org-noter--property-auto-save-last-location (format "%s" new-setting)))
        (unless new-setting (org-entry-delete nil org-noter-property-note-location)))))))

(defun org-noter-set-hide-other (arg)
  "This toggles hiding other headings for the current session.
- With a prefix \\[universal-argument], set the current setting permanently for this document.
- With a prefix \\[universal-argument] \\[universal-argument], remove the setting and use the default."
  (interactive "P")
  (org-noter--with-valid-session
   (let* ((inhibit-read-only t)
          (ast (org-noter--parse-root))
          (persistent
           (cond ((equal arg '(4)) 'write)
                 ((equal arg '(16)) 'remove)))
          (new-setting
           (cond ((eq persistent 'write) (org-noter--session-hide-other session))
                 ((eq persistent 'remove) org-noter-hide-other)
                 ('other-cases (not (org-noter--session-hide-other session))))))
     (setf (org-noter--session-hide-other session) new-setting)
     (when persistent
       (with-current-buffer (org-noter--session-notes-buffer session)
         (org-with-wide-buffer
          (goto-char (org-element-property :begin ast))
          (if (eq persistent 'write)
              (org-entry-put nil org-noter--property-hide-other (format "%s" new-setting))
            (org-entry-delete nil org-noter--property-hide-other))))))))

(defun org-noter-set-closest-tipping-point (arg)
  "This sets the closest note tipping point (see `org-noter-closest-tipping-point')
- With a prefix \\[universal-argument], set it permanently for this document.
- With a prefix \\[universal-argument] \\[universal-argument], remove the setting and use the default."
  (interactive "P")
  (org-noter--with-selected-notes-window
   (let* ((ast (org-noter--parse-root))
          (inhibit-read-only t)
          (persistent (cond ((equal arg '(4)) 'write)
                            ((equal arg '(16)) 'remove)))
          (new-setting (if (eq persistent 'remove)
                           org-noter-closest-tipping-point
                         (read-number "New tipping point: " (org-noter--session-closest-tipping-point session)))))
     (setf (org-noter--session-closest-tipping-point session) new-setting)
     (when persistent
       (org-with-wide-buffer
        (goto-char (org-element-property :begin ast))
        (if (eq persistent 'write)
            (org-entry-put nil org-noter--property-closest-tipping-point (format "%f" new-setting))
          (org-entry-delete nil org-noter--property-closest-tipping-point)))))))

(defun org-noter-set-notes-window-behavior (arg)
  "Set the notes window behaviour for the current session.
With a prefix ARG, it becomes persistent for that document.

See `org-noter-notes-window-behavior' for more information."
  (interactive "P")
  (org-noter--with-valid-session
   (let* ((inhibit-read-only t)
          (ast (org-noter--parse-root))
          (behavior-possibilities
           '(("Default" . nil)
             ("On start and scroll" . (start scroll))
             ("On start" . (start))
             ("On scroll" . (scroll))
             ("Never" . (never))))
          (behavior
           (cdr (assoc (completing-read "Behavior: " behavior-possibilities nil t)
                       behavior-possibilities))))
     (setf (org-noter--session-window-behavior session)
           (or behavior org-noter-notes-window-behavior))
     (when arg
       (with-current-buffer (org-noter--session-notes-buffer session)
         (org-with-wide-buffer
          (goto-char (org-element-property :begin ast))
          (if behavior
              (org-entry-put nil org-noter--property-behavior
                             (format "%s" behavior))
            (org-entry-delete nil org-noter--property-behavior))))))))

(defun org-noter-set-notes-window-location (arg)
  "Set the notes window default location for the current session.
With a prefix ARG, it becomes persistent for that document.

See `org-noter-notes-window-behavior' for more information."
  (interactive "P")
  (org-noter--with-valid-session
   (let* ((inhibit-read-only t)
          (ast (org-noter--parse-root))
          (location-possibilities
           '(("Default" . nil)
             ("Horizontal split" . horizontal-split)
             ("Vertical split" . vertical-split)
             ("Other frame" . other-frame)))
          (location
           (cdr (assoc (completing-read "Location: " location-possibilities nil t)
                       location-possibilities)))
          (notes-buffer (org-noter--session-notes-buffer session)))

     (setf (org-noter--session-window-location session)
           (or location org-noter-notes-window-location))

     (let (exists)
       (dolist (window (get-buffer-window-list notes-buffer nil t))
         (setq exists t)
         (with-selected-frame (window-frame window)
           (if (= (count-windows) 1)
               (delete-frame)
             (delete-window window))))
       (when exists (org-noter--get-notes-window 'force)))

     (when arg
       (with-current-buffer notes-buffer
         (org-with-wide-buffer
          (goto-char (org-element-property :begin ast))
          (if location
              (org-entry-put nil org-noter--property-location
                             (format "%s" location))
            (org-entry-delete nil org-noter--property-location))))))))

(defun org-noter-kill-session (&optional session)
  "Kill an `org-noter' session.

When called interactively, if there is no prefix argument and the
buffer has an annotation session, it will kill it; else, it will
show a list of open `org-noter' sessions, asking for which to
kill.

When called from elisp code, you have to pass in the SESSION you
want to kill."
  (interactive "P")
  (when (and (called-interactively-p 'any) (> (length org-noter--sessions) 0))
    ;; NOTE(nox): `session' is representing a prefix argument
    (if (and org-noter--session (not session))
        (setq session org-noter--session)
      (setq session nil)
      (let (collection default doc-display-name notes-file-name display)
        (dolist (session org-noter--sessions)
          (setq doc-display-name (org-noter--session-display-name session)
                notes-file-name (file-name-nondirectory
                                 (org-noter--session-notes-file-path session))
                display (concat doc-display-name " - " notes-file-name))
          (when (eq session org-noter--session) (setq default display))
          (push (cons display session) collection))
        (setq session (cdr (assoc (completing-read "Which session? " collection nil t
                                                   nil nil default)
                                  collection))))))

  (when (and session (memq session org-noter--sessions))
    (setq org-noter--sessions (delq session org-noter--sessions))

    (when (eq (length org-noter--sessions) 0)
      (remove-hook 'delete-frame-functions 'org-noter--handle-delete-frame)
      (advice-remove 'doc-view-goto-page 'org-noter--location-change-advice)
      (advice-remove 'nov-render-document 'org-noter--nov-scroll-handler))

    (let* ((ast (org-noter--parse-root))
           (frame (org-noter--session-frame session))
           (notes-buffer (org-noter--session-notes-buffer session))
           (base-buffer (buffer-base-buffer notes-buffer))
           (notes-modified (buffer-modified-p base-buffer))
           (doc-buffer (org-noter--session-doc-buffer session)))

      (dolist (window (get-buffer-window-list notes-buffer nil t))
        (with-selected-frame (window-frame window)
          (if (= (count-windows) 1)
              (delete-frame)
            (delete-window window))))

      (with-current-buffer notes-buffer
        (remove-hook 'kill-buffer-hook 'org-noter--handle-kill-buffer t)
        (restore-buffer-modified-p nil))
      (kill-buffer notes-buffer)

      (with-current-buffer base-buffer
        (org-noter--unset-read-only ast)
        (set-buffer-modified-p notes-modified))

      (with-current-buffer doc-buffer
        (remove-hook 'kill-buffer-hook 'org-noter--handle-kill-buffer t))
      (kill-buffer doc-buffer)

      (when (frame-live-p frame)
        (if (= (length (frames-on-display-list)) 1)
            (progn
              (delete-other-windows)
              (set-frame-parameter nil 'name nil))
          (delete-frame frame))))))

(defun org-noter-create-skeleton ()
  "Create notes skeleton with the PDF outline or annotations.
Only available with PDF Tools."
  (interactive)
  (org-noter--with-valid-session
   (cond
    ((eq (org-noter--session-doc-mode session) 'pdf-view-mode)
     (let* ((ast (org-noter--parse-root))
            (top-level (org-element-property :level ast))
            (options '(("Outline" . (outline))
                       ("Annotations" . (annots))
                       ("Both" . (outline annots))))
            answer output-data)
       (with-current-buffer (org-noter--session-doc-buffer session)
         (setq answer (assoc (completing-read "What do you want to import? " options nil t) options))

         (when (memq 'outline answer)
           (dolist (item (pdf-info-outline))
             (let ((type  (alist-get 'type item))
                   (page  (alist-get 'page item))
                   (depth (alist-get 'depth item))
                   (title (alist-get 'title item))
                   (top   (alist-get 'top item)))
               (when (and (eq type 'goto-dest) (> page 0))
                 (push (vector title (cons page top) (1+ depth) nil) output-data)))))

         (when (memq 'annots answer)
           (let ((possible-annots (list '("Highlights" . highlight)
                                        '("Underlines" . underline)
                                        '("Squigglies" . squiggly)
                                        '("Text notes" . text)
                                        '("Strikeouts" . strike-out)
                                        '("Links" . link)
                                        '("ALL" . all)))
                 chosen-annots insert-contents pages-with-links)
             (while (> (length possible-annots) 1)
               (let* ((chosen-string (completing-read "Which types of annotations do you want? "
                                                      possible-annots nil t))
                      (chosen-pair (assoc chosen-string possible-annots)))
                 (cond ((eq (cdr chosen-pair) 'all)
                        (dolist (annot possible-annots)
                          (when (and (cdr annot) (not (eq (cdr annot) 'all)))
                            (push (cdr annot) chosen-annots)))
                        (setq possible-annots nil))
                       ((cdr chosen-pair)
                        (push (cdr chosen-pair) chosen-annots)
                        (setq possible-annots (delq chosen-pair possible-annots))
                        (when (= 1 (length chosen-annots)) (push '("DONE") possible-annots)))
                       (t
                        (setq possible-annots nil)))))

             (setq insert-contents (y-or-n-p "Should we insert the annotations contents? "))

             (dolist (item (pdf-info-getannots))
               (let* ((type  (alist-get 'type item))
                      (page  (alist-get 'page item))
                      (edges (or (org-noter--pdf-tools-edges-to-region (alist-get 'markup-edges item))
                                 (alist-get 'edges item)))
                      (top (nth 1 edges))
                      (item-subject (alist-get 'subject item))
                      (item-contents (alist-get 'contents item))
                      name contents)
                 (when (and (memq type chosen-annots) (> page 0))
                   (if (eq type 'link)
                       (cl-pushnew page pages-with-links)
                     (setq name (cond ((eq type 'highlight)  "Highlight")
                                      ((eq type 'underline)  "Underline")
                                      ((eq type 'squiggly)   "Squiggly")
                                      ((eq type 'text)       "Text note")
                                      ((eq type 'strike-out) "Strikeout")))

                     (when insert-contents
                       (setq contents (cons (pdf-info-gettext page edges)
                                            (and (or (and item-subject (> (length item-subject) 0))
                                                     (and item-contents (> (length item-contents) 0)))
                                                 (concat (or item-subject "")
                                                         (if (and item-subject item-contents) "\n" "")
                                                         (or item-contents ""))))))

                     (push (vector (format "%s on page %d" name page) (cons page top) 'inside contents)
                           output-data)))))

             (dolist (page pages-with-links)
               (let ((links (pdf-info-pagelinks page))
                     type)
                 (dolist (link links)
                   (setq type (alist-get 'type  link))
                   (unless (eq type 'goto-dest) ;; NOTE(nox): Ignore internal links
                     (let* ((edges (alist-get 'edges link))
                            (title (alist-get 'title link))
                            (top (nth 1 edges))
                            (target-page (alist-get 'page link))
                            target heading-text)

                       (unless (and title (> (length title) 0)) (setq title (pdf-info-gettext page edges)))

                       (cond
                        ((eq type 'uri)
                         (setq target (alist-get 'uri link)
                               heading-text (format "Link on page %d: [[%s][%s]]" page target title)))

                        ((eq type 'goto-remote)
                         (setq target (concat "file:" (alist-get 'filename link))
                               heading-text (format "Link to document on page %d: [[%s][%s]]" page target title))
                         (when target-page
                           (setq heading-text (concat heading-text (format " (target page: %d)" target-page)))))

                        (t (error "Unexpected link type")))

                       (push (vector heading-text (cons page top) 'inside nil) output-data))))))))

         (when output-data
           (setq output-data
                 (sort output-data
                       (lambda (e1 e2)
                         (or (not (aref e1 1))
                             (and (aref e2 1)
                                  (org-noter--compare-location-cons '< (aref e1 1) (aref e2 1)))))))
           (push (vector "Skeleton" nil 1 nil) output-data)))

       (with-current-buffer (org-noter--session-notes-buffer session)
         ;; NOTE(nox): org-with-wide-buffer can't be used because we want to reset the
         ;; narrow region to include the new headings
         (widen)
         (save-excursion
           (goto-char (org-element-property :end ast))

           (let (last-absolute-level
                 title location relative-level contents
                 level)
             (dolist (data output-data)
               (setq title          (aref data 0)
                     location       (aref data 1)
                     relative-level (aref data 2)
                     contents       (aref data 3))

               (if (symbolp relative-level)
                   (setq level (1+ last-absolute-level))
                 (setq last-absolute-level (+ top-level relative-level)
                       level last-absolute-level))

               (org-noter--insert-heading level title)

               (when location
                 (org-entry-put nil org-noter-property-note-location (org-noter--pretty-print-location location)))

               (when (car contents)
                 (org-noter--insert-heading (1+ level) "Contents")
                 (insert (car contents)))
               (when (cdr contents)
                 (org-noter--insert-heading (1+ level) "Comment")
                 (insert (cdr contents)))))

           (setq ast (org-noter--parse-root))
           (org-noter--narrow-to-root ast)
           (goto-char (org-element-property :begin ast))
           (outline-hide-subtree)
           (org-show-children 2)))))

    (t (error "This command is only supported on PDF Tools.")))))

(defun org-noter-insert-note (&optional precise-location)
  "Insert note associated with the current location.

This command will prompt for a title of the note and then insert
it in the notes buffer. When the input is empty, a title based on
`org-noter-default-heading-title' will be generated.

If there are other notes related to the current location, the
prompt will also suggest them. Depending on the value of the
variable `org-noter-closest-tipping-point', it may also
suggest the closest previous note.

PRECISE-LOCATION makes the new note associated with a more
specific location (see `org-noter-insert-precise-note' for more
info).

When you insert into an existing note and have text selected on
the document buffer, the variable `org-noter-insert-selected-text-inside-note'
defines if the text should be inserted inside the note."
  (interactive "P")
  (org-noter--with-valid-session
   (let* ((ast (org-noter--parse-root)) (contents (org-element-contents ast))
          (window (org-noter--get-notes-window 'force))
          (location-cons (org-noter--doc-approx-location (or precise-location 'infer)))
          (view-info (org-noter--get-view-info (org-noter--get-current-view) location-cons))

          (selected-text
           (cond
            ((eq (org-noter--session-doc-mode session) 'pdf-view-mode)
             (when (pdf-view-active-region-p)
               (mapconcat 'identity (pdf-view-active-region-text) ? )))

            ((eq (org-noter--session-doc-mode session) 'nov-mode)
             (when (region-active-p)
               (buffer-substring-no-properties (mark) (point)))))))

     (let ((inhibit-quit t))
       (with-local-quit
         (select-frame-set-input-focus (window-frame window))
         (select-window window)

         ;; IMPORTANT(nox): Need to be careful changing the next part, it is a bit
         ;; complicated to get it right...

         (let ((point (point))
               collection default title selection
               (target-post-blank (if org-noter-separate-notes-from-heading 2 1)))

           ;; NOTE(nox): When precise, it will certainly be a new note
           (if precise-location
               (setq default (and selected-text (replace-regexp-in-string "\n" " " selected-text)))

             (dolist (note-cons (org-noter--view-info-notes view-info))
               (let ((display (org-element-property :raw-value (car note-cons))))
                 (push (cons display note-cons) collection)
                 (when (>= point (org-element-property :begin (car note-cons)))
                   (setq default display)))))

           (setq collection (nreverse collection)
                 title (completing-read "Note: " collection nil nil nil nil default)
                 selection (cdr (assoc title collection)))

           (if selection
               ;; NOTE(nox): Inserting on an existing note
               (let* ((reference-element (cdr selection))
                      (has-content
                       (org-element-map (org-element-contents reference-element) org-element-all-elements
                         (lambda (element) (not (memq (org-element-type element) '(section property-drawer))))
                         nil t))
                      (post-blank (org-element-property :post-blank reference-element)))

                 (when has-content (setq target-post-blank 2))

                 (goto-char (org-element-property :end reference-element))

                 ;; NOTE(nox): Org doesn't count `:post-blank' when at the end of the buffer
                 (when (org-next-line-empty-p) ;; This is only true at the end, I think
                   (goto-char (point-max))
                   (save-excursion
                     (beginning-of-line)
                     (while (looking-at "[[:space:]]*$")
                       (setq post-blank (1+ post-blank))
                       (beginning-of-line 0))))

                 (while (< post-blank target-post-blank)
                   (insert "\n")
                   (setq post-blank (1+ post-blank)))

                 (when (org-at-heading-p)
                   (forward-line -1))

                 (when (and org-noter-insert-selected-text-inside-note selected-text) (insert selected-text)))

             ;; NOTE(nox): Inserting a new note
             (let ((reference-element-cons (org-noter--view-info-reference-for-insertion view-info)))
               (when (zerop (length title))
                 (setq title (replace-regexp-in-string (regexp-quote "$p$") (number-to-string (car location-cons))
                                                       org-noter-default-heading-title)))

               (if reference-element-cons
                   (progn
                     (cond
                      ((eq (car reference-element-cons) 'before)
                       (goto-char (org-element-property :begin (cdr reference-element-cons))))
                      ((eq (car reference-element-cons) 'after)
                       (goto-char (org-element-property :end (cdr reference-element-cons)))))

                     (org-noter--insert-heading (org-element-property :level (cdr reference-element-cons)) title
                                                target-post-blank))

                 (goto-char (org-element-map contents 'section (lambda (section) (org-element-property :end section))
                                             nil t org-element-all-elements))
                 ;; NOTE(nox): This is needed to insert in the right place...
                 (outline-show-entry)
                 (org-noter--insert-heading (1+ (org-element-property :level ast)) title target-post-blank))

               (org-entry-put nil org-noter-property-note-location (org-noter--pretty-print-location location-cons))

               (setf (org-noter--session-num-notes-in-view session)
                     (1+ (org-noter--session-num-notes-in-view session)))))

           (org-show-context)
           (org-show-siblings)
           (org-show-subtree)
           (org-cycle-hide-drawers 'all)))
       (when quit-flag
         ;; NOTE(nox): If this runs, it means the user quitted while creating a note, so
         ;; revert to the previous window.
         (select-frame-set-input-focus (org-noter--session-frame session))
         (select-window (get-buffer-window (org-noter--session-doc-buffer session))))))))

(defun org-noter-insert-precise-note ()
  "Insert note associated with a specific location.
This will ask you to click where you want to scroll to when you
sync the document to this note. You should click on the top of
that part. Will always create a new note.

When text is selected, it will automatically choose the top of
the selected text as the location and the text itself as the
title of the note (you may change it anyway!).

See `org-noter-insert-note' docstring for more."
  (interactive)
  (org-noter--with-valid-session
   (let ((location (cond
                    ((and (eq (org-noter--session-doc-mode session) 'pdf-view-mode)
                          (pdf-view-active-region-p))
                     (cadar (pdf-view-active-region)))

                    ((and (eq (org-noter--session-doc-mode session) 'nov-mode)
                          (region-active-p))
                     (min (mark) (point)))

                    (t (org-noter--ask-precise-location)))))
     (org-noter-insert-note location))))

(defun org-noter-sync-prev-page-or-chapter ()
  "Show previous page or chapter that has notes, in relation to the current page or chapter.
This will force the notes window to popup."
  (interactive)
  (org-noter--with-valid-session
   (let ((location-cons (org-noter--doc-approx-location 0))
         (contents (org-element-contents (org-noter--parse-root)))
         target-location)
     (org-noter--get-notes-window 'force)

     (org-element-map contents 'headline
       (lambda (headline)
         (let ((location (org-noter--location-property headline)))
           (when (and (org-noter--compare-location-cons '<  location location-cons)
                      (org-noter--compare-location-cons '>f location target-location))
             (setq target-location location))))
       nil nil org-noter--note-search-no-recurse)

     (org-noter--get-notes-window 'force)
     (select-window (org-noter--get-doc-window))
     (if target-location
         (org-noter--doc-goto-location target-location)
       (user-error "There are no more previous pages or chapters with notes")))))

(defun org-noter-sync-current-page-or-chapter ()
  "Show current page or chapter notes.
This will force the notes window to popup."
  (interactive)
  (org-noter--with-valid-session
   (let ((window (org-noter--get-notes-window 'force)))
     (select-frame-set-input-focus (window-frame window))
     (select-window window)
     (org-noter--doc-location-change-handler))))

(defun org-noter-sync-next-page-or-chapter ()
  "Show next page or chapter that has notes, in relation to the current page or chapter.
This will force the notes window to popup."
  (interactive)
  (org-noter--with-valid-session
   (let ((location-cons (org-noter--doc-approx-location most-positive-fixnum))
         (contents (org-element-contents (org-noter--parse-root)))
         target-location)

     (org-element-map contents 'headline
       (lambda (headline)
         (let ((location (org-noter--location-property headline)))
           (when (and (org-noter--compare-location-cons '> location location-cons)
                      (org-noter--compare-location-cons '< location target-location))
             (setq target-location location))))
       nil nil org-noter--note-search-no-recurse)

     (org-noter--get-notes-window 'force)
     (select-window (org-noter--get-doc-window))
     (if target-location
         (org-noter--doc-goto-location target-location)
       (user-error "There are no more following pages or chapters with notes")))))

(defun org-noter-sync-prev-note ()
  "Go to the location of the previous note, in relation to where the point is.
As such, it will only work when the notes window exists."
  (interactive)
  (org-noter--with-selected-notes-window
   "No notes window exists"
   (let ((org-noter--inhibit-location-change-handler t)
         (contents (org-element-contents (org-noter--parse-root)))
         (current-begin
          (org-element-property :begin (org-noter--get-containing-heading)))
         previous)
     (when current-begin
       (org-element-map contents 'headline
         (lambda (headline)
           (when (org-noter--location-property headline)
             (if (= current-begin (org-element-property :begin headline))
                 t
               (setq previous headline)
               nil)))
         nil t org-noter--note-search-no-recurse))

     (if previous
         (progn
           ;; NOTE(nox): This needs to be manual so we can focus the correct note
           (org-noter--doc-goto-location (org-noter--location-property previous))
           (org-noter--focus-notes-region (org-noter--make-view-info-for-single-note previous)))
       (error "There is no previous note"))))
  (select-window (org-noter--get-doc-window)))

(defun org-noter-sync-current-note ()
  "Go the location of the selected note, in relation to where the point is.
As such, it will only work when the notes window exists."
  (interactive)
  (org-noter--with-selected-notes-window
   "No notes window exists"
   (let ((location (org-noter--location-property (org-noter--get-containing-heading))))
     (if location
         (org-noter--doc-goto-location location)
       (error "No note selected"))))
  (let ((window (org-noter--get-doc-window)))
    (select-frame-set-input-focus (window-frame window))
    (select-window window)))

(defun org-noter-sync-next-note ()
  "Go to the location of the next note, in relation to where the point is.
As such, it will only work when the notes window exists."
  (interactive)
  (org-noter--with-selected-notes-window
   "No notes window exists"
   (let ((org-noter--inhibit-location-change-handler t)
         (contents (org-element-contents (org-noter--parse-root)))
         next)
     (org-element-map contents 'headline
       (lambda (headline)
         (when (and
                (org-noter--location-property headline)
                (< (point) (org-element-property :begin headline)))
           (setq next headline)))
       nil t org-noter--note-search-no-recurse)

     (if next
         (progn
           (org-noter--doc-goto-location (org-noter--location-property next))
           (org-noter--focus-notes-region (org-noter--make-view-info-for-single-note next)))
       (error "There is no next note"))))
  (select-window (org-noter--get-doc-window)))

(define-minor-mode org-noter-doc-mode
  "Minor mode for the document buffer."
  :keymap `((,(kbd   "i")   . org-noter-insert-note)
            (,(kbd "M-i")   . org-noter-insert-precise-note)
            (,(kbd   "q")   . org-noter-kill-session)
            (,(kbd "M-p")   . org-noter-sync-prev-page-or-chapter)
            (,(kbd "M-.")   . org-noter-sync-current-page-or-chapter)
            (,(kbd "M-n")   . org-noter-sync-next-page-or-chapter)
            (,(kbd "C-M-p") . org-noter-sync-prev-note)
            (,(kbd "C-M-.") . org-noter-sync-current-note)
            (,(kbd "C-M-n") . org-noter-sync-next-note))

  (let ((mode-line-segment '(:eval (org-noter--mode-line-text))))
    (if org-noter-doc-mode
        (if (symbolp (car-safe mode-line-format))
            (setq mode-line-format (list mode-line-segment mode-line-format))
          (push mode-line-segment mode-line-format))
      (setq mode-line-format (delete mode-line-segment mode-line-format)))))

(define-minor-mode org-noter-notes-mode
  "Minor mode for the notes buffer."
  :keymap `((,(kbd "M-p")   . org-noter-sync-prev-page-or-chapter)
            (,(kbd "M-.")   . org-noter-sync-current-page-or-chapter)
            (,(kbd "M-n")   . org-noter-sync-next-page-or-chapter)
            (,(kbd "C-M-p") . org-noter-sync-prev-note)
            (,(kbd "C-M-.") . org-noter-sync-current-note)
            (,(kbd "C-M-n") . org-noter-sync-next-note)))

;;;###autoload
(defun org-noter (&optional arg)
  "Start `org-noter' session.

There are two modes of operation. You may create the session from:
- The Org notes file
- The document to be annotated (PDF, EPUB, ...)

- Creating the session from notes file -----------------------------------------
This will open a session for taking your notes, with indirect
buffers to the document and the notes side by side. Your current
window configuration won't be changed, because this opens in a
new frame.

You only need to run this command inside a heading (which will
hold the notes for this document). If no document path property is found,
this command will ask you for the target file.

With a prefix universal argument ARG, only check for the property
in the current heading, don't inherit from parents.

With a prefix number ARG:
- Greater than 0: Open the document like `find-file'
-     Equal to 0: Create session with `org-noter-always-create-frame' toggled
-    Less than 0: Open the folder containing the document

- Creating the session from the document ---------------------------------------
This will try to find a notes file in any of the parent folders.
The names it will search for are defined in `org-noter-default-notes-file-names'.
It will also try to find a notes file with the same name as the
document, giving it the maximum priority.

When it doesn't find anything, it will interactively ask you what
you want it to do. The target notes file must be in a parent
folder (direct or otherwise) of the document.

You may pass a prefix ARG in order to make it let you choose the
notes file, even if it finds one."
  (interactive "P")
  (cond
   ;; NOTE(nox): Creating the session from notes file
   ((eq major-mode 'org-mode)
    (when (org-before-first-heading-p)
      (error "`org-noter' must be issued inside a heading"))

    (let* ((notes-file-path (buffer-file-name))
           (document-property (org-entry-get nil org-noter-property-doc-file (not (equal arg '(4)))))
           (document-path (when (stringp document-property) (expand-file-name document-property)))
           (org-noter-always-create-frame (if (and (numberp arg) (= arg 0))
                                              (not org-noter-always-create-frame)
                                            org-noter-always-create-frame))
           ast)

      (unless (and document-path (not (file-directory-p document-path)) (file-readable-p document-path))
        (setq document-path (expand-file-name
                             (read-file-name
                              "Invalid or no document property found. Please specify a document path: "
                              nil nil t)))
        (when (or (file-directory-p document-path) (not (file-readable-p document-path)))
          (user-error "Invalid file path"))

        (setq document-property (if (y-or-n-p "Do you want a relative file name? ")
                                    (file-relative-name document-path)
                                  document-path))
        (org-entry-put nil org-noter-property-doc-file document-property))

      (setq ast (org-noter--parse-root (current-buffer) document-property))
      (when (catch 'should-continue
              (when (or (numberp arg) (eq arg '-))
                (cond ((> (prefix-numeric-value arg) 0)
                       (find-file document-path)
                       (throw 'should-continue nil))
                      ((< (prefix-numeric-value arg) 0)
                       (find-file (file-name-directory document-path))
                       (throw 'should-continue nil))))

              ;; NOTE(nox): Test for existing sessions
              (dolist (test-session org-noter--sessions)
                (when (org-noter--valid-session test-session)
                  (let ((test-buffer (org-noter--session-notes-buffer test-session))
                        (test-notes-file (org-noter--session-notes-file-path test-session))
                        (test-property (org-noter--session-property-text test-session))
                        test-ast)
                    (when (and (string= test-notes-file notes-file-path)
                               (string= test-property document-property))
                      (setq test-ast (org-noter--parse-root test-buffer test-property))
                      (when (eq (org-element-property :begin ast)
                                (org-element-property :begin test-ast))

                        (let* ((org-noter--session test-session)
                               (location (org-noter--location-property (org-noter--get-containing-heading))))
                          (org-noter--setup-windows test-session)

                          (when location (org-noter--doc-goto-location location))

                          (select-frame-set-input-focus (org-noter--session-frame test-session)))
                        (throw 'should-continue nil))))))
              t)
        (org-noter--create-session ast document-property notes-file-path))))

   ;; NOTE(nox): Creating the session from the annotated document
   ((memq major-mode '(doc-view-mode pdf-view-mode nov-mode))
    (if (org-noter--valid-session org-noter--session)
        (progn (org-noter--setup-windows org-noter--session)
               (select-frame-set-input-focus (org-noter--session-frame org-noter--session)))

      ;; NOTE(nox): `buffer-file-truename' is a workaround for modes that delete
      ;; `buffer-file-name', and may not have the same results
      (let* ((buffer-file-name (or buffer-file-name (bound-and-true-p nov-file-name)))
             (document-path (or buffer-file-name buffer-file-truename
                                (error "This buffer does not seem to be visiting any file")))
             (document-name (file-name-nondirectory document-path))
             (document-base (file-name-base document-name))
             (document-directory (if buffer-file-name
                                     (file-name-directory buffer-file-name)
                                   (if (file-equal-p document-name buffer-file-truename)
                                       default-directory
                                     (file-name-directory buffer-file-truename))))
             ;; NOTE(nox): This is the path that is actually going to be used, and should
             ;; be the same as `buffer-file-name', but is needed for the truename workaround
             (document-used-path (expand-file-name document-name document-directory))

             (search-names (append org-noter-default-notes-file-names (list (concat document-base ".org"))))
             notes-files-annotating     ; List of files annotating document
             notes-files                ; List of found notes files (annotating or not)

             (document-location (org-noter--doc-approx-location 'infer)))

        ;; NOTE(nox): Check the search path
        (dolist (path org-noter-notes-search-path)
          (dolist (name search-names)
            (let ((file-name (expand-file-name name path)))
              (when (file-exists-p file-name)
                (push file-name notes-files)
                (when (org-noter--check-if-document-is-annotated-on-file document-path file-name)
                  (push file-name notes-files-annotating))))))

        ;; NOTE(nox): `search-names' is in reverse order, so we only need to (push ...)
        ;; and it will end up in the correct order
        (dolist (name search-names)
          (let ((directory (locate-dominating-file document-directory name))
                file)
            (when directory
              (setq file (expand-file-name name directory))
              (unless (member file notes-files) (push file notes-files))
              (when (org-noter--check-if-document-is-annotated-on-file document-path file)
                (push file notes-files-annotating)))))

        (setq search-names (nreverse search-names))

        (when (or arg (not notes-files-annotating))
          (when (or arg (not notes-files))
            (let* ((notes-file-name (completing-read "What name do you want the notes to have? "
                                                     search-names nil t))
                   list-of-possible-targets
                   target)

              ;; NOTE(nox): Create list of targets from current path
              (catch 'break
                (let ((current-directory document-directory)
                      file-name)
                  (while t
                    (setq file-name (expand-file-name notes-file-name current-directory))
                    (when (file-exists-p file-name)
                      (setq file-name (propertize file-name 'display
                                                  (concat file-name
                                                          (propertize " -- Exists!"
                                                                      'face '(foreground-color . "green")))))
                      (push file-name list-of-possible-targets)
                      (throw 'break nil))

                    (push file-name list-of-possible-targets)

                    (when (string= current-directory
                                   (setq current-directory
                                         (file-name-directory (directory-file-name current-directory))))
                      (throw 'break nil)))))
              (setq list-of-possible-targets (nreverse list-of-possible-targets))

              ;; NOTE(nox): Create list of targets from search path
              (dolist (path org-noter-notes-search-path)
                (when (file-exists-p path)
                  (let ((file-name (expand-file-name notes-file-name path)))
                    (unless (member file-name list-of-possible-targets)
                      (when (file-exists-p file-name)
                        (setq file-name (propertize file-name 'display
                                                    (concat file-name
                                                            (propertize " -- Exists!"
                                                                        'face '(foreground-color . "green"))))))
                      (push file-name list-of-possible-targets)))))

              (setq target (completing-read "Where do you want to save it? " list-of-possible-targets
                                            nil t))
              (set-text-properties 0 (length target) nil target)
              (unless (file-exists-p target) (write-region "" nil target))

              (setq notes-files (list target))))

          (when (> (length notes-files) 1)
            (setq notes-files (list (completing-read "In which notes file should we create the heading? "
                                                     notes-files nil t))))

          (if (member (car notes-files) notes-files-annotating)
              ;; NOTE(nox): This is needed in order to override with the arg
              (setq notes-files-annotating notes-files)
            (with-current-buffer (find-file-noselect (car notes-files))
              (goto-char (point-max))
              (insert (if (save-excursion (beginning-of-line) (looking-at "[[:space:]]*$")) "" "\n")
                      "* " document-base)
              (org-entry-put nil org-noter-property-doc-file
                             (file-relative-name document-used-path
                                                 (file-name-directory (car notes-files)))))
            (setq notes-files-annotating notes-files)))

        (when (> (length notes-files-annotating) 1)
          (setq notes-files-annotating (list (completing-read "Which notes file should we open? "
                                                              notes-files-annotating nil t))))

        (with-current-buffer (find-file-noselect (car notes-files-annotating))
          (org-with-wide-buffer
           (catch 'break
             (goto-char (point-min))
             (while (re-search-forward (org-re-property org-noter-property-doc-file) nil t)
               (when (file-equal-p (expand-file-name (match-string 3)
                                                     (file-name-directory (car notes-files-annotating)))
                                   document-path)
                 (let ((org-noter--start-location-override document-location))
                   (org-noter))
                 (throw 'break t)))))))))))

(provide 'org-noter)

;;; org-noter.el ends here
