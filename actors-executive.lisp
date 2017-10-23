
(in-package :actors-base)

;; --------------------------------------------------------
;; Executive service routines

;; NOTE: Under the scheme below an Actor is running for as long as it
;; remains alive and also has messages pending in its mailbox. We rely
;; on the existence of other Executive threads to avoid stalling other
;; Actors. But this scheme effectively nullifies the use of PAUSE
;; inside of Actor code.
;;
;; We got rid of the CATCH/THROW, and implemented restartable Actors
;; so that we can actually debug things again.

(defun do-run-actor (actor)
  (loop do
        ;;
        ;; We need to capture consistent values from these slots,
        ;; in case a REMOVE-ACTOR is being performed from another
        ;; thread.
        ;;
        (with-actor-values ((mbox  actor-next-messages)
                            (behav actor-next-behavior)) actor
          (cond ((and behav
                      (or (null mbox)
                          (mp:mailbox-not-empty-p mbox)))
                 (let ((*current-actor* actor))
                   (apply behav (when mbox
                                  ;; always a list from SEND
                                  (mp:mailbox-read mbox)))
                   ))
                
                (t
                 ;; the Actor either has no more messages, or else
                 ;; item must have been terminated with REMOVE-ACTOR
                 ;; from this or another thread. We let ADD-ACTOR
                 ;; decide future eligibility for running.
                 ;;
                 (add-actor actor) ;; throw fish back into the sea...
                 (loop-finish))
                )))
  actor) ;; return non-nil

(defun report-termination (actor)
  (unless *muffle-exits*
    (pr
     (format nil "~&~A terminated"
             (actor-name actor)))
    ))

(defun run-actor (actor)
  ;;
  ;; run the actor for as long as it can. We must finish with either a
  ;; REMOVE-ACTOR or an ADD-ACTOR.
  ;;
  (let (okay)
    (unwind-protect
        (restart-case
            (handler-case
                (setf okay (do-run-actor actor))
              
              (actor-termination-condition (cx)
                (declare (ignore cx))
                ;; the actor requested termination
                (report-termination actor)))
    
          (:terminate-actor ()
            :report "Terminate Actor"
            ;; this restart avoids killing off the entire Executive
            ;; thread, but the Actor is toast at this point...
            ))
      
      ;; unwind protect
      (unless okay
        (remove-actor actor))
      )))

(defun executive-loop ()
  ;; the main executive loop
  (loop for actor = (pop-ready-queue)
        do
        (when actor
          (setf *last-heartbeat* (get-universal-time))
          (run-actor actor))))

;; ----------------------------------------------------------------------------
;; Implement a pool of Actor Executives (= nbr cores) to dispatch on a
;; shared queue of actor states.
;;
;; Since we can't know, in general, whether an Actor will be kind
;; enough to avoid blocking actions, we implement a heartbeat timer to
;; periodically scan the executive pool looking to see if all of the
;; existing executives are tied up. This could happen from Actors
;; calling blocking I/O functions, or even if Acters behaved
;; themselves but were intensely compute bound.
;;
;; Each executive updates the timestamp with the last time it launched
;; a running Actor from the ready queue. If there are waiting Actors
;; in the ready queue, and the timestamp appears older than
;; +maximum-age+ at the time of the periodic watchdog check, then we
;; assume that we should allocate another executive to help out.

(defun check-sufficient-execs ()
  (let (age)
    (unless (or (ready-queue-empty-p)
                (progn
                  (setf age (- (get-universal-time) *last-heartbeat*))
                  (< age +maximum-age+)))
      (let ((nexecs (length *executive-processes*)))
        (cond ((>= nexecs +max-pool+)
               (mp:unschedule-timer *heartbeat-timer*)
               (error "Something is causing an excessive number of Executive threads to be spawned."))
              (t
               (pr
                (format nil "~&Last heartbeat ~A secs ago. Spawning another Executive to help." age))
               (push-new-executive))
              )))))

(um:defmonitor
    ;; under a global lock
    
    ((push-new-executive ()
       (push (mp:process-run-function
              (format nil "Actor Executive ~D" (incf *executive-counter*))
              '()
              #'executive-loop)
             *executive-processes*))

     (ensure-executives ()
       (unless *executive-processes*
         (dotimes (ix +nbr-execs+)
           (push-new-executive)))
       (unless *heartbeat-timer*
         (setf *heartbeat-timer* (mp:make-timer #'check-sufficient-execs)))
       (mp:schedule-timer-relative
        *heartbeat-timer*
        +heartbeat-interval+
        +heartbeat-interval+))
     
     (kill-executives ()
       (let ((timer (shiftf *heartbeat-timer* nil)))
         (when timer
           (mp:unschedule-timer timer)
           (setf *last-heartbeat* 0)))
       (let ((procs (shiftf *executive-processes* nil)))
         (setf *executive-counter* 0
               *muffle-exits*      nil)
         (dolist (proc procs)
           (ignore-errors
             (mp:process-terminate proc)))
         (empty-ready-queue)
         ))))

#|
(def-factory make-time-eater (arg)
    ()
  (print arg)
  (let ((mbox (mp:make-mailbox)))
    (mp:mailbox-read mbox)))

(progn
  (loop repeat +nbr-execs+ do
        (let ((actor (make-time-eater)))
          (send actor 15)))
  (loop repeat 1000 do
        (sleep (1+ +maximum-age+))
        (send (time-eater) 15)))
  
 |#

