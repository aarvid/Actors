
(in-package :actors-base)

;; --------------------------------------------------------------------
;; NOTE: MP:MAILBOX supports multiple readers, not just multiple
;; writers. So use a mailbox for the FIFO Actor ready queue.

(defun add-to-ready-queue (actor)
  ;; actor should already be locked
  (setf (actor-residence actor) *actor-ready-queue*)
  (mp:mailbox-send *actor-ready-queue* actor)
  (unless *executive-processes*
    (ensure-executives)))

(defun ready-queue-empty-p ()
  (mp:mailbox-empty-p *actor-ready-queue*))

(defun empty-ready-queue ()
  (let ((old-mb  (sys:atomic-exchange *actor-ready-queue*
                                      (mp:make-mailbox))))
    ;; nudge any Executives waiting on the queue to move over to the
    ;; new one.
    (map nil (lambda (proc)
               (declare (ignore proc))
               (mp:mailbox-send old-mb nil))
         *executive-processes*)
    ))

(defun pop-ready-queue ()
  (mp:mailbox-read *actor-ready-queue*))

#|
(defun find-in-queue (item queue &key (key 'identity) (test 'eql))
  (declare (ignore item queue key test))
  nil)

(defun queue-remove (actor queue)
  (declare (ignore actor queue))
  nil)
|#
