;; actors-macros.lisp -- actually, defuns that need to be in place for the macros to be defined later

(in-package #:actors-macros)

;; --------------------------------------------------------

(defun anaphor (sym)
  ;; ensure that a like symbol is interned into the user's current
  ;; package, e.g., (let ((a!self (anaphor 'self)) ...)
  (intern (string sym)))

(defun gensym-like (sym)
  (gensym (string sym)))


;; --------------------------------------------------------------------


