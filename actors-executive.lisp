
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
        (let ((mbox  (actor-messages actor))
              (behav (actor-behavior actor)))
          (cond ((and behav
                      (mp:mailbox-not-empty-p mbox))
                 (let ((*current-actor* actor))
                   (apply behav actor (when mbox
                                        ;; always a list from SEND
                                        (mp:mailbox-read mbox)))
                   ))
                
                (t  (loop-finish))
                )) ))

(defun run-actor (actor)
  ;;
  ;; run the actor for as long as it can. We must finish with ADD-ACTOR
  ;;
  (unwind-protect
      (restart-case
          (do-run-actor actor)
        
        (:terminate-actor ()
          :report "Terminate Actor"
          ;; this restart avoids killing off the entire Executive
          ;; thread, but the Actor is toast at this point...
          ))
    (add-actor actor)))

;; --------------------------------------------------------------

(defun get-next-actor ()
  (prog2
      (setf (mp:process-property :waiting-for-actor) t)
      (pop-ready-queue)
    (setf (mp:process-property :waiting-for-actor) nil
          *last-heartbeat* (get-universal-time))))

(defun waiting-for-actor-p (proc)
  (mp:process-property :waiting-for-actor proc))

(defun executive-loop ()
  ;; the main executive loop
  (unwind-protect
      (loop for actor = (get-next-actor)
            do
            (when actor
              (run-actor actor)))
    (remove-from-pool (mp:get-current-process))))

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
                (find-waiting-executive)
                (progn
                  (setf age (- (get-universal-time) *last-heartbeat*))
                  (< age +maximum-age+)))
      (mp:unschedule-timer (shiftf *heartbeat-timer* nil))
      (mp:process-run-function
       "Stalling Actors" ()
       (lambda ()
         (restart-case
             (error "Actor Executives are stalled (blocked waiting or compute bound). ~&Last heartbeat was ~A sec ago."
                    age)
           (:spawn-new-executive ()
             :report "Spawn another Executive"
             (push-new-executive))
           (:stop-actor-system ()
             :report "Stop Actor system"
             (kill-executives))
           ))
       ))))

(um:defmonitor
    ;; under a global lock

    ((find-waiting-executive ()
       (some #'waiting-for-actor-p *executive-processes*))

     (remove-from-pool (proc)
       (setf *executive-processes* (delete proc *executive-processes*)))
     
     (push-new-executive ()
       (push (mp:process-run-function
              (format nil "Actor Executive ~D" (incf *executive-counter*))
              '()
              'executive-loop) ;; use of symbol is intentional
             *executive-processes*)
       (unless *heartbeat-timer*
         (setf *heartbeat-timer*
               (mp:make-timer 'check-sufficient-execs)) ;; use of symbol intentional
         (mp:schedule-timer-relative
          *heartbeat-timer*
          +heartbeat-interval+
          +heartbeat-interval+)))

     (ensure-executives ()
       (unless *executive-processes*
         (dotimes (ix +nbr-execs+)
           (push-new-executive))))
     
     (kill-executives ()
       (let ((timer (shiftf *heartbeat-timer* nil)))
         (when timer
           (mp:unschedule-timer timer)
           (setf *last-heartbeat* 0)))
       (let ((procs (shiftf *executive-processes* nil)))
         (setf *executive-counter* 0)
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

