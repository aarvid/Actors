
(in-package :actors-base)

;; --------------------------------------------------------
;; Executive service routines

(defun run-actor (actor)
  (loop do
        ;; We need locked consistent values from these slots, in case a
        ;; REMOVE-ACTOR is performed in another thread.
        (with-actor-values ((mbox  actor-next-messages)
                            (behav actor-next-behavior)) actor
          (cond ((and behav
                      (or (null mbox)
                          (mp:mailbox-not-empty-p mbox)))
                 (multiple-value-bind (ans err)
                     (ignore-errors
                       (catch :ACTOR
                         (let ((*current-actor* actor))
                           ;; provide the actor as the first argument
                           ;; for his SELF
                           (apply behav actor (when mbox
                                                ;; always a list from send
                                                (mp:mailbox-read mbox)))
                           )))
                   (declare (ignore _))
                   (cond (err
                          ;; if the actor suffered an error, we terminate any
                          ;; further interactions with it
                          (pr
                           (format nil "~&~A terminated on error:"
                                   (actor-name actor))
                           (format nil "~&  ~A" err))
                          (remove-actor actor)
                          (loop-finish))
                         
                         ((null ans)
                          ;; the actor requested termination
                          (unless *muffle-exits*
                            (pr
                             (format nil "~&~A terminated"
                                     (actor-name actor))))
                          (remove-actor actor)
                          (loop-finish))
                         )))
                
                (t ;; no longer ready to run, but give add-actor
                   ;; another shot at it under locked access to avoid
                   ;; a race condition where the actor goes quiescent
                   ;; even though a send had just come in.
                   (add-actor actor)
                   (loop-finish))
                ))))

(defun executive-loop ()
  ;; the main executive loop
  (loop for actor = (pop-queue *actor-ready-queue*)
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
;; Each executive marks itself with a timestamp of the last time it
;; checked for availble Actors in the ready queue. If all executive
;; timestamps are older than +maximum-age+ from the time at the
;; periodic check, then we assume that we should allocate another
;; executive to help out.

(defun check-sufficient-execs ()
  (let (age)
    (unless (or (queue-empty-p *actor-ready-queue*)
                (progn
                  (setf age (- (get-universal-time) *last-heartbeat*))
                  (< age +maximum-age+)))
      (let ((nexecs (length *executive-processes*)))
        (cond ((>= nexecs +max-pool+)
               (mp:unschedule-timer *heartbeat-timer*)
               (error "Serious bottlenecks appear to be the case!"))
              (t
               (pr
                (format nil "~&Last heartbeat ~A secs ago. Spawning another Executive to help" age))
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
         (setf *heartbeat-timer* (mp:make-timer #'check-sufficient-execs))
         (mp:schedule-timer-relative
          *heartbeat-timer*
          +heartbeat-interval+
          +heartbeat-interval+)))
     
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
         (queue-empty *actor-ready-queue*)
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

