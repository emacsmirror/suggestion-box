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

;; This package is more or less for major-mode maintainers who want to
;; show type information on the cursor and currently only tested on
;; nim-mode (https://github.com/nim-lang/nim-mode).

;; The tooltip will be placed above on the current cursor, so most of
;; the time, the tooltip doesn't destruct your auto-completion result.

;; How to use:
;;
;; if you just want to show type information after company-mode's
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

;;; Code:

;; TODO:
;;  - escape comma inside strings
;;  - minor-mode?

(require 'popup)
(require 'cl-lib)
(require 'cl-generic)
(require 'subr-x) ; need Emacs 25.1 or later for `when-let' and `if-let'
(require 'eieio)

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

(defclass suggestion-box-data ()
  ((bound :initarg :bound)
   (popup :type popup :initarg :popup)
   (content :type string :initarg :content))
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


(cl-defgeneric suggestion-box-set-obj (backend popup-obj original-string)
  "Set data to `suggestion-box-data'.
The `suggestion-box-data' has to include POPUP-OBJ and able to get
popup object from `suggestion-box-get-popup'.")

(cl-defgeneric suggestion-box-close-predicate (backend)
  "Predicate function.
Return non-nil if suggestion-box need to close.")

(cl-defgeneric suggestion-box-trim (backend string)
  "Trim STRING.")

(cl-defgeneric suggestion-box-split (backend string)
  "Return list of string.")

(cl-defgeneric suggestion-box-get-nth (backend)
  "Return a number, which represent Nth's arg.")

(cl-defgeneric suggestion-box-filter (backend string)
  "Return filtered STRING.")



;;; Default backend

(cl-defmethod suggestion-box-set-obj ((_backend (eql default)) popup-obj string)
  (setq suggestion-box-obj
        (make-instance 'suggestion-box-data
                       :bound (nth 1 (syntax-ppss)) ; at "(" after function
                       :popup popup-obj
                       :content string)))

(cl-defmethod suggestion-box-close-predicate ((_backend (eql default)))
  (not (eq (suggestion-box-get-bound)
           (nth 1 (syntax-ppss)))))

(cl-defmethod suggestion-box-trim ((_backend (eql default)) string)
  (substring string
             (cl-search "(" string)
             (1+ (cl-search ")" string :from-end t))))

(cl-defmethod suggestion-box-split ((_backend (eql default)) string)
  (split-string string ", "))

(cl-defmethod suggestion-box-get-nth ((_backend (eql default)))
  (let ((start (nth 1 (syntax-ppss))))
    (length (split-string (buffer-substring start (point)) ",") )))

(cl-defmethod suggestion-box-filter ((_backend (eql default)) string)
  (cl-loop with bend = 'default
           with nth-arg = (suggestion-box-get-nth bend)
           with strs = (delq nil (suggestion-box-split bend (suggestion-box-trim bend string)))
           with count = 0
           for s in strs
           do (setq count (1+ count))
           if (eq count nth-arg)
           collect s into result
           else if (<= (length strs) count)
           collect "?" into result
           else collect "." into result
           finally return (mapconcat 'identity result ", ")))

;; Getters
(defun suggestion-box-get-popup ()
  (when-let ((obj suggestion-box-obj))
    (with-slots (popup) obj popup)))

(defun suggestion-box-get-str ()
  (when-let ((obj suggestion-box-obj))
    (with-slots (content) obj content)))

(defun suggestion-box-get-bound ()
  (when-let ((obj suggestion-box-obj))
    (with-slots (bound) obj bound)))



;; Core

;;;###autoload
(defun suggestion-box (string)
  "Show STRING on the cursor."
  (when-let ((backend (suggestion-box-find-backend)))
    (when-let ((str (and string (suggestion-box-filter backend string))))
      (suggestion-box-delete)
      (suggestion-box-set-obj
       backend (suggestion-box--tip str :truncate t) string)
      (add-hook 'post-command-hook 'suggestion-box--update nil t))))

(defun suggestion-box--update ()
  "Delete existing popup object inside `suggestion-box-data'."
  (when-let ((data suggestion-box-obj))
    (when-let ((backend (suggestion-box-find-backend)))
      (if (not (or (suggestion-box-close-predicate backend)
                   (eq 'keyboard-quit this-command)))
          ;; TODO: add highlight current argument
          (suggestion-box (suggestion-box-get-str))
        ;; Delete popup obj
        (suggestion-box-delete)
        (remove-hook 'post-command-hook 'suggestion-box--update t)))))

(defun suggestion-box-delete ()
  "Delete suggestion-box."
  (when-let ((p (suggestion-box-get-popup)))
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
