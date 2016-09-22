;;; suggestion-box.el --- show tooltip on the cursor -*- lexical-binding: t; -*-

;; Copyright (C) 2016  Yuta Yamada

;; Author: Yuta Yamada <cokesboy"at"gmail.com>
;; Keywords: convenience
;; Version: 0.0.1
;; Package-Requires: ((emacs "25.1") (popup "0.5.3"))

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

;; Note: this package is still early stage. I'm going to
;; support [nim-mode](https://github.com/nim-lang/nim-mode) first and
;; then other programming major-modes.
;;
;; If your nim-mode merged this PR (https://github.com/nim-lang/nim-mode/pull/138)
;; and you already configured nimsuggest, you can use suggestion-box
;; without configuration.
;;
;;
;; This package is more or less for major-mode maintainers who want to
;; show type information on the cursor and currently only tested on
;; nim-mode (https://github.com/nim-lang/nim-mode).

;; The tooltip will be placed above on the current cursor, so most of
;; the time, the tooltip doesn't destruct your auto-completion result.

;; How to implement:
;;
;; if you want to show type information after company-mode's
;; :post-completion or :exit-function for `completion-at-point',
;; you may implement something like this:
;;
;;   (defun xxx-completion-at-point ()
;;      ... ; do something
;;     :exit-function (lambda (string status)
;;                      (if STRING-IS-FUNCTION
;;                         (insert "()")
;;                         (backward-char 1)
;;                         (suggestion-box TYPE-INFO)))
;;     )
;;
;;
;; But, I might change API to reduce defgeneric/defmethod stuff, so
;; please keep in mind this package isn't stable yet.
;;
;;; Code:

(require 'popup)
(require 'cl-lib)
(require 'eieio)
(require 'rx)
(require 'subr-x) ; need Emacs 25.1 or later for `when-let', `if-let'
                  ; and also `alist-get' in subr.el


(defgroup suggestion-box nil
  "Show information on the cursor."
  :link '(url-link "https://github.com/yuutayamada/suggestion-box-el")
  :group 'suggestion-box)

(defface suggestion-box-face
  '((((class color) (background dark))
     (:background "#00ffff" :foreground "black"))
    (((class color) (background light))
     (:background "#000087"  :foreground "white"))
    (t (:inverse-video t)))
  "Face for suggestion-box's tooltip."
  :group 'suggestion-box)



;;; Variables
(defcustom suggestion-box-messages
  '((:many-args    . "too many arguments?")
    (:inside-paren . "_"))
  "Messages that occasionally pop up"
  :group 'suggestion-box
  :type 'string)

(defcustom suggestion-box-default-masks (cons "." "?")
  "Default masks."
  :group 'suggestion-box
  :type (cons 'string 'string))

(defclass suggestion-box-data ()
  ((bound   :initarg :bound)
   (popup   :initarg :popup   :type popup)
   (content :initarg :content :type string)
   (ppss    :initarg :ppss))
  :documentation "wip")

(defvar suggestion-box-obj nil
  "Internal variable to store popup object and other properties.")



;;; API

(defvar suggestion-box-backend-functions nil
  "Special hook to find the suggestion-box backend for the current context.
Each function on this hook is called in turn with no arguments,
and should return either nil to mean that it is not applicable,
or an suggestion-box backend, which is a value to be used to dispatch the
generic functions.")

(defun suggestion-box--general-backend () 'default)
(add-hook 'suggestion-box-backend-functions #'suggestion-box--general-backend t)

;;;###autoload
(defun suggestion-box-find-backend ()
  (run-hook-with-args-until-success 'suggestion-box-backend-functions))

(defun suggestion-box-get (name)
  (when suggestion-box-obj
    (slot-value suggestion-box-obj name)))

(cl-defgeneric suggestion-box-close-predicate (backend bound)
  "Predicate function that returns non-nil if suggestion-box needs to close.
The value of BOUND is that you will be implemented at `suggestion-box-get-boundary'.")

(cl-defgeneric suggestion-box-trim (backend string)
  "Return trimmed string.")

(cl-defgeneric suggestion-box-split (backend string)
  "Return list of string.")

(cl-defgeneric suggestion-box-get-nth (backend)
  "Return a number, which represent Nth's arg.")


;; Those generic functions can be optional to implement
(cl-defgeneric suggestion-box-get-boundary (_backend)
  "Return something to indicate boundary to delete suggestion-box later."
  'paren)

(cl-defgeneric suggestion-box-get-mask (_backend)
  "Return cons of strings or nil. Both car and cdr parts are used to
hide filtered string. If nil is returned, doesn't hide."
  suggestion-box-default-masks)



;;; Default backend

(cl-defmethod suggestion-box-close-predicate ((_backend (eql default)) _bound)
  (not (suggestion-box-h-inside-paren-p)))

(cl-defmethod suggestion-box-trim ((_backend (eql default)) string)
  (suggestion-box-h-trim string "(" ")"))

(cl-defmethod suggestion-box-split ((_backend (eql default)) string)
  (split-string string ", "))

(cl-defmethod suggestion-box-get-nth ((_backend (eql default)))
  (suggestion-box-h-get-nth "," 'paren))


;; Helper functions
(defun suggestion-box-h-inside-paren-p ()
  (memq (nth 1 (suggestion-box-get 'ppss)) (nth 9 (syntax-ppss))))

(defun suggestion-box-h-trim (string opener closer)
  (substring string
             (when-let ((start (cl-search opener string)))
               (1+ start))
             (when-let (end (cl-search closer string :from-end t))
               end)))

(defun suggestion-box-h-get-nth (sep start-pos)
  (save-excursion
    (when-let ((start (if (eq 'paren start-pos)
                          (nth 1 (suggestion-box-get 'ppss))
                        start-pos))
               (r (apply `((lambda () (rx (or (eval (list 'syntax ?\))) ,sep))))))
               (count 1))
      (while (re-search-backward r start t)
        (let ((ppss (syntax-ppss)))
          (if (eq ?\) (char-syntax (char-after (point))))
              ;; 8th of ppss is start position of comment or string.
              ;; comment would be rare case, but maybe it's
              ;; beneficial for languages like haskell, which has
              ;; multi-comment.
              (goto-char (or (nth 8 ppss) (nth 1 ppss) (point)))
            (when (not (nth 8 ppss))
              (setq count (1+ count))))))
      count)))



;; Core

;;;###autoload
(cl-defun suggestion-box (string &key still-inside)
  "Show STRING on the cursor."
  (when-let ((backend (and string (suggestion-box-find-backend))))
    (when-let ((str (suggestion-box--normalize backend string)))
      (suggestion-box--delete)
      (suggestion-box--set-obj
       (suggestion-box--tip str :truncate t)
       string
       (or (car still-inside)
           (suggestion-box-get-boundary backend))
       (or (cdr still-inside)
           (syntax-ppss)))
      (add-hook 'post-command-hook 'suggestion-box--update nil t))))

(defun suggestion-box--normalize (backend str)
  (suggestion-box--filter backend (suggestion-box-trim backend str)))

(defun suggestion-box--inside-paren-p ()
  (not (eq (nth 1 (syntax-ppss))
           (nth 1 (suggestion-box-get 'ppss)))))

(defun suggestion-box--filter (backend string)
  (let* ((strs (delq nil (suggestion-box-split backend string)))
         (max (length strs))
         (nth-arg (suggestion-box-get-nth backend)))
    (cond
     ((suggestion-box--inside-paren-p)
      (alist-get :inside-paren suggestion-box-messages))
     ((< max nth-arg)
      (alist-get :many-args suggestion-box-messages))
     (t
      (cl-loop with count = 0
               with mask = (suggestion-box-get-mask backend)
               for s in strs
               do (setq count (1+ count))
               if (eq count nth-arg)
               collect s into result
               else if (<= max count)
               collect (or (cdr mask) s) into result
               else collect (or (car mask) s) into result
               finally return (mapconcat 'identity result ", "))))))

(defun suggestion-box--set-obj (popup-obj string boundary ppss)
  (setq suggestion-box-obj
        (make-instance 'suggestion-box-data
                       :bound boundary
                       :popup popup-obj
                       :content string
                       :ppss ppss)))

(defun suggestion-box--update ()
  "Update suggestion-box.
This function is registered to `post-command-hook' and used to
update suggestion-box. If `suggestion-box-close-predicate'
returns non-nil, delete current suggestion-box and registered
function `post-command-hook'."
  (when-let ((backend (and suggestion-box-obj
                           (suggestion-box-find-backend))))
    (let ((bound (suggestion-box-get 'bound)))
      (cond
       ((or (suggestion-box-close-predicate backend bound)
            (eq 'keyboard-quit this-command))
        (suggestion-box--reset))
       (t (suggestion-box (suggestion-box-get 'content)
                          :still-inside
                          (cons bound
                                (and (suggestion-box--inside-paren-p)
                                     (suggestion-box-get 'ppss)))))))))

(defun suggestion-box--reset ()
  (suggestion-box--delete)
  (setq suggestion-box-obj nil)
  (remove-hook 'post-command-hook 'suggestion-box--update t))

(defun suggestion-box--delete ()
  "Delete suggestion-box."
  (when-let ((p (suggestion-box-get 'popup)))
    (popup-delete p)))

(cl-defun suggestion-box--tip (str &key truncate &aux tip width lines)
  (when (< 1 (line-number-at-pos))
    (cl-letf* (((symbol-function 'popup-calculate-direction)
                (lambda (&rest _r) -1)))
      (let ((s (substring str 0 (min (- (window-width) (current-column))
                                     (length str)))))
        (let ((it (popup-fill-string s nil popup-tip-max-width)))
          (setq width (car it))
          (setq lines (cdr it)))
        (setq tip (popup-create nil width 1
                                :min-height nil
                                :max-width nil
                                :around t
                                :margin-left nil
                                :margin-right nil
                                :scroll-bar nil
                                :face 'suggestion-box-face
                                :parent nil
                                :parent-offset nil))
        (unwind-protect
            (when (> (popup-width tip) 0)                   ; not to be corrupted
              (when (and (not (eq width (popup-width tip))) ; truncated
                         (not truncate))
                ;; Refill once again to lines be fitted to popup width
                (setq width (popup-width tip))
                (setq lines (cdr (popup-fill-string s width width))))
              (popup-set-list tip lines)
              (popup-draw tip)
              tip))))))


(provide 'suggestion-box)
;;; suggestion-box.el ends here
