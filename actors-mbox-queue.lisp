
(in-package :actors-base)

;; --------------------------------------------------------------------
;; NOTE: MP:MAILBOX supports multiple readers, not just multiple
;; writers. So use a mailbox for the FIFO Actor ready queue.

(defun not-already-in-queue-p (actor)
  ;; return true if not in queue, but also mark it as being in the
  ;; ready queue if it wasn't
  (sys:compare-and-swap (car (actor-residence actor)) nil t))

(defun mark-not-in-queue (actor)
  (setf (car (actor-residence actor)) nil))

(defun add-to-ready-queue (actor)
  (when (and (actor-behavior actor)
             (not-already-in-queue-p actor))
    (mp:mailbox-send *actor-ready-queue* actor)
    (unless *executive-processes*
      (ensure-executives))))

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

