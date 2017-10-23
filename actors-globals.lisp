
(in-package :actors-globals)

;; ----------------------------------------------------------------------------

(defconstant +nbr-execs+          4)
(defconstant +max-pool+         100)
(defvar *executive-processes*   nil)
(defvar *executive-counter*       0)

(defconstant +heartbeat-interval+ 1)
(defconstant +maximum-age+        3)
(defvar *heartbeat-timer*       nil)
(defvar *last-heartbeat*          0)
(defvar *muffle-exits*          nil)

;; --------------------------------------------------------------------

(define-condition actor-termination-condition (serious-condition)
  ())

(defconstant +actor-termination+
  (make-condition 'actor-termination-condition))

;; --------------------------------------------------------------------

(defvar *current-actor*  nil)

(defun current-actor ()
  *current-actor*)

(defvar *actor-ready-queue*  (mp:make-mailbox))

;; --------------------------------------------------------------------

(defvar *actor-directory-manager* #'lw:do-nothing)


(defun blind-print (cmd &rest items)
  (declare (ignore cmd))
  (dolist (item items)
    (print item)))

(defvar *shared-printer-actor*    #'blind-print)


