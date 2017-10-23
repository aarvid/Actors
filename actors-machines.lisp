
(in-package #:actors-machines)

;; ----------------------------------------------------------------

(defun find-kw-assoc (kw lst)
  (let ((test (um:curry #'eq kw)))
    (multiple-value-bind (pre post)
        (um:split-if test lst)
      (if post
          (values (cadr post) t
                  (um:nlet-tail flush ((pre  pre)
                                       (tl   (cddr post)))
                    (multiple-value-bind (hd new-tl) (um:split-if test tl)
                      (let ((new-pre (nconc pre hd)))
                        (if new-tl
                            (flush new-pre (cddr new-tl))
                          new-pre)
                        ))) )
        (values nil nil lst))
      )))

(defun parse-clauses (clauses)
  (multiple-value-bind (preamble preamble-present-p clauses)
      (find-kw-assoc :PREAMBLE clauses)
    (multiple-value-bind (timeout timeout-present-p clauses)
        (find-kw-assoc :TIMEOUT clauses)
      (multiple-value-bind (on-timeout on-timeout-present-p clauses)
          (find-kw-assoc :ON-TIMEOUT clauses)
        (values clauses
                preamble preamble-present-p
                timeout timeout-present-p
                on-timeout on-timeout-present-p)
        ))))

(defun dlambda-clauses-p (clauses)
  (labels ((dlambda-clause-p (clause)
             (optima:match clause
               ((list* _ (or (eql :WHEN)
                             (eql :UNLESS))
                       _ _)
                nil)
               ((list* kw args _) :when (and (symbolp kw)
                                             (listp args))
                t)
               (_  nil))))
    (every #'dlambda-clause-p clauses)))

(defun parse-pattern-clauses (msg preamble clauses)
  `(lambda (,msg)
     ,@(when preamble
         `(,preamble))
     ,(if (dlambda-clauses-p clauses)
          `(um:dcase ,msg
             ,@(mapcar (lambda (clause)
                         (destructuring-bind (key args . body) clause
                           `(,key ,args (lambda () ,@body))))
                       clauses))
        ;; else - optima clauses
        `(optima:match ,msg  ;; returns NIL on no matching message, as we need
           ,@(mapcar (lambda (clause)
                       (optima:ematch clause
                         ((list pat (or (and wen
                                             (eql :WHEN))
                                        (and wen
                                             (eql :UNLESS)))
                                pred . body)
                          `(,pat ,wen ,pred (lambda () ,@body)))
                         
                         ((list pat . body)
                          `(,pat (lambda () ,@body)))
                         ))
                     clauses)) )
     ))

;; ----------------------------------------------------------------

(define-condition actors-exn (error)
  ((err-reason :reader err-reason :initarg :reason :initform :abnormal
               :documentation "The reason for the exit.")
   (err-arg    :reader err-arg    :initarg :arg  :initform nil
               :documentation "Any additional arguments for this exit.")
   (err-from   :reader err-from   :initarg :from :initform (current-actor)
               :documentation "The PID of the process that produced this exit condition."))
  (:report report-actors-exn)
  (:documentation "An Actors system error condition."))

(define-condition actors-exn-timeout (actors-exn)
  ()
  (:documentation "A subclass of actors-exn for timeouts"))

(defun report-actors-exn (err stream)
  "Report the exit condition as a printable item.
Only works for PRINC, and FORMAT ~A not FORMAT ~S or ~W"
  (um:if-let (arg (err-arg err))
      (format stream "Exit: ~A ~A~%From: ~A"
              (err-reason err) arg (err-from err))
    (format stream "Exit: ~A~%From: ~A"
            (err-reason err) (err-from err))
    ))

(defun timed-out (self)
  "Internal routine to generate the timeout exception to the current
process."
  (error (make-instance 'actors-exn-timeout
                        :from   self
                        :reason :ABNORMAL
                        :arg    :TIMEOUT)))

(defun actor-timeout-timer (actor)
  (get-actor-property actor 'timeout-timer))

(defsetf actor-timeout-timer (actor) (timer)
  `(setf (get-actor-property ,actor 'timeout-timer) ,timer))
         
(defun unschedule-timeout (actor)
  (let ((timer (actor-timeout-timer actor)))
    (when timer
      (mp:unschedule-timer timer))
    ))

(defun schedule-timeout (actor duration)
  ;; Calling SCHEDULE-TIMEOUT on an Actor that already has a pending
  ;; timeout, cancels the pending timeout and initiates with the
  ;; current duration.
  (labels ((tell-him ()
             (send actor :self-timed-out actor)))
    (with-locked-actor (actor)
      (unschedule-timeout actor)
      (with-accessors ((its-timer  actor-timeout-timer)) actor
        (cond ((null duration) )
              
              ((not (realp duration))
               (error "Timeout duration must be a real number"))
              
              ((plusp duration)
               (let ((timer (or its-timer
                                (setf its-timer (mp:make-timer #'tell-him)))))
                 (mp:schedule-timer-relative timer duration)))
              
              (t  ;; negative or zero timeout duration
                  (tell-him))
              )))
    actor)) ;; might be helpful to act like SETF and return the actor

;; ----------------------------------------------------------------
;; Scheduled Actors - Actors with RECV clauses. Scheduled only in the
;; sense that they may receive a timeout message before any
;; recognizable messages arrive. Can only happen if someone calls
;; SCHEDULE-TIMEOUT on the Actor.

(defun handle-scheduled-actor (self msg conds-fn timeout-fn)
  (um:dcase msg
    (:self-timed-out (actor)
     (when (eq actor self)
       (funcall timeout-fn)))
    (t (&rest _)
       (declare (ignore _))
       (let ((fn (funcall conds-fn msg)))
         (when fn
           (unschedule-timeout self)
           (funcall fn))))
    ))


(defmacro recv (msg &rest clauses)
  ;; a RECV uses Optima:MATCH style patterns and clauses. The only
  ;; thing offered here by a RECV, over using OPTIMA:MATCH, is the
  ;; possible use of an ON-TIMEOUT clause. Unlike Butterfly RECV, we
  ;; can't specify a timeout parameter with TIMEOUT because that must
  ;; be initiated from outside of the Actor.
  ;;
  ;; Actors don't sit and wait and selectively retrieve from a
  ;; mailbox. Rather they are handed messages by an Executive whenever
  ;; they are allowed to run. An Actor either handles the message, or
  ;; drops it on the floor.
  ;;
  ;; There is no concept of waiting for a message with timeout,
  ;; initiated from with the Actor code. It isn't even allowed to run
  ;; until a message is sent to it. The Executive can't be bothered
  ;; with selective retrieval from the Actor's mailbox. That's up to
  ;; the Actor as messages stream by.
  ;;
  ;; We still re-parse the handler body to create a function which
  ;; takes a message and returns a fully deconstructed pattern match
  ;; closure, or nil. This allows us to cancel any pending timeout if
  ;; a message will be handled.
  ;;
  ;; Timeouts are initiated externally by calling SCHEDULE-TIMEOUT on
  ;; an Actor. Only RECV Actors can respond to a timeout. If they
  ;; handle it with an ON-TIMEOUT clause then okay, otherwise they
  ;; will generate a timeout error, unless some recognizable message
  ;; arrives before then.
  ;;
  ;; This macro is supposed to handle either of Optima:MATCH or
  ;; DLAMBDA style clauses, but not mixed together.
  ;;
  (multiple-value-bind (new-clauses
                        preamble          preamble-present-p
                        timeout-expr      timeout-present-p
                        on-timeout-clause on-timeout-present-p)
      (parse-clauses clauses)
    (declare (ignore timeout-expr timeout-present-p preamble-present-p))
    (let* ((conds-fn       (parse-pattern-clauses msg preamble new-clauses))
           (a!self         (anaphor 'self))
           (timeout-fn     (if on-timeout-present-p
                               `(lambda ()
                                  ,on-timeout-clause)
                             `(lambda ()
                                (timed-out ,a!self)))))
      `(handle-scheduled-actor ,a!self ,msg ,conds-fn ,timeout-fn))
    ))

(defmacro perform-with-timeout (msg timeout &rest clauses)
  (let ((g!actor (gensym-like :actor-)))
    `(let ((,g!actor (make-actor #:perform (&rest ,msg)
                         ()
                       (recv ,msg
                         ,@clauses))))
       (schedule-timeout ,g!actor ,timeout)
       ,g!actor)
    ))

#|
(kill-executives)
(defun tst (dt)
  (let* ((x 15)
         (self :me!)
         (actor (perform-with-timeout msg 2
                                      ((list :print val) (pr val))
                                      ((list :who)       (pr self))
                                      ((list :quit)      (terminate))
                                      :ON-TIMEOUT (progn
                                                    (pr :Timed-Out!)
                                                    (setf x 32)
                                                    (terminate)))))
    (pr actor)
    (sleep dt)
    (send actor :who)
    (send actor :print :hello)
    (send actor :quit)
    (pr x)))
(compile 'tst)
(tst 1)
(let ((x (make-actor #:test (&rest msg)
             ()
           (recv msg
             ((list :print val)
              (pr val))
             ((list :quit)
              (terminate))
             :ON-TIMEOUT
             (progn
               (pr :Ouch)
               (terminate))))
         ))
  (schedule-timeout x 5)
  (inspect x)
  (sleep 6)
  (send x :print :Hello?)
  (send x :quit))

 |#
;; -----------------------------------------------------------------------
;; State Machine Actors...
#|
(defmethod parse-handler-clauses ((disp (eql 'UM:DCASE)) msg clauses)
  (let* ((keys   (mapcar #'car clauses))
         (args   (mapcar #'cadr clauses))
         (bodies (mapcar #'cddr clauses)))
    `(lambda (,msg)
       (um:dcase ,msg
         ,@(mapcar #3`(,a1 ,a2 (lambda () ,@a3))
                   keys args bodies)))
    ))
                     

(defmethod parse-handler-clauses ((disp (eql 'OPTIMA:MATCH)) msg clauses)
  (parse-pattern-clauses msg nil clauses))

(defmethod parse-handler-clauses ((disp (eql 'RECV)) msg clauses)
  (parse-pattern-clauses msg nil clauses))

(defmacro parse-state-handler (handler-block)
  (optima:match handler-block
    ((list* disp msg clauses)
     (parse-handler-clauses disp msg clauses))
    (_
     (error "Invalid handler form"))
    ))
|#

(defstruct message-queue
  ;; a device that saves messages and returns all of them in FIFO
  ;; order, all at once, clearing the queue for the next round...
  lst)

(defun mq-save (mq msg)
  (push msg (message-queue-lst mq)))

(defun mq-get-all (mq)
  ;; this gets back all the enqueued messages in FIFO order
  ;; and clears the queue
  (nreverse (shiftf (message-queue-lst mq) nil)))

(defun do-handle-state-machine-message (msg state-ref backlog state-handlers)
  (labels
      ((handle-message (msg)
         (symbol-macrolet ((state (car state-ref)))
           ;; GETF uses EQ comparison -- identical
           (um:if-let (fn (getf state-handlers state)) ;; get state handlers
               ;; we got the handler function. It takes a message and
               ;; returns a closure to call for that message, or nil
               ;; on no handler.
               (let ((old-state state))
                 (funcall fn msg) ;; this might change state...
                 ;;
                 ;; it is responsibility of the programmer to decide
                 ;; when/if to stash messages it doesn't want to handle.
                 ;;
                 ;; But at every change of state, we retry the stashed
                 ;; messages in case the new state can handle them
                 ;;
                 (unless (eq state old-state)
                   (map nil #'handle-message 
                        (mq-get-all backlog))) )  ;; this clears the backlog
             ;; else
             (error "Invalid state")))
         ))
    (handle-message msg)))
      
(defmacro make-state-machine (name msg state-bindings initial-state &rest groups)
  ;; Every Actor has a name, possibly some non-empty initial
  ;; internal-state bindings and a body.  A state-machine also takes
  ;; the name used to refer to messages in the body, an initial state
  ;; value for machine state, and a collection of handlers for each
  ;; state. The body will be synthesized for use by the state machine
  ;; grinder.
  (let ((a!self (anaphor 'self))
        (a!me   (anaphor 'me))
        (g!backlog   (gensym-like :backlog-))
        (g!state-ref (gensym-like :state-ref-))
        (a!new-state (anaphor 'new-state))
        (a!save-message (anaphor 'save-message))
        (g!msg       (gensym-like :msg-))
        (g!state     (gensym-like :state-)))
    `(let (,a!self
           (,g!state-ref  (list ,initial-state))
           (,g!backlog    (make-message-queue)))
       (let ,state-bindings
         (labels ((,a!me (&rest ,msg)
                    (macrolet ((,a!new-state (,g!state)
                                 `(setf (car ,',g!state-ref) ,,g!state))
                               (,a!save-message (,g!msg)
                                 `(mq-save ,',g!backlog ,,g!msg)))
                      ;; inside the body code you can do (NEW-STATE xx) to set the state
                      ;; and (SAVE-MESSAGE msg) to stuff a message into the backlog
                      (do-handle-state-machine-message
                       ,msg
                       ,g!state-ref ,g!backlog
                       (list ;; a plist of state indicator, handler function
                        ,@(mapcan #`(,(car a1) (lambda (,msg)
                                                 ,(cadr a1)))
                                  groups)))
                      (next)
                      )))
           (prog1
               (setf ,a!self (make-instance 'Actor
                                            :name ',name
                                            :lambda-list '(&rest msg)
                                            :behav #',a!me))
             (add-actor ,a!self)))
         ))
    ))

(editor:setup-indent "make-state-machine" 4)

#|
(defun tst ()
  (let ((x  (make-state-machine :diddle msg
                (val) :initial
              
              (:initial (um:dcase msg
                          (:echo (x)
                           (pr x))
                          (:who  ()
                           (pr self))
                          (:test (x)
                           (setf val x)
                           (new-state :one))
                          (:quit ()
                           (terminate))))
              
              (:one     (um:dcase msg
                          (:try (x)
                           (pr (+ x val))
                           (new-state :initial))
                          (t (&rest _)
                             (save-message msg)))))
            ))
    (send x :echo :This)
    (send x :who)
    (send x :test 15)
    (send x :who)
    (send x :echo :That)
    (send x :try 32)
    (send x :quit)))
(compile 'tst)
(tst)

(parse-state-handler
 (um:dcase msgx
   (pat1 args1 body1)
   (pat2 args2 body2)))

(recv msg
  (pat1 clause1)
  (pat2 clause2))

(let ((x (make-actor :X (&rest msg)
             ()
           (recv msg
             ((list :echo arg)
              (print arg)
              (terminate))
             #||#
             :ON-TIMEOUT (progn
                           (print "Hey! I timed out!")
                           (terminate))
             #||#
             ))))
  (schedule-timeout x 3)
  (send x :diddly)
  (sleep 2)
  (send x :echo :This))

;; ---------------------------------------------------
(progn
  (defvar *ct* 0)
  (def-factory make-stupid (&rest msg) ()
    (progn
      (setf *muffle-exits* t)
      (um:dcase msg
        (:quit ()
         (sys:atomic-incf *ct*)
         #|
         (when (= *ct* 1000000)
           (print "You hit the jackpot!"))
         |#
         (terminate)))))
  
  (defun tst (n)
    (setf *ct* 0)
    (let ((old-muffle (shiftf *muffle-exits* t)))
      (unwind-protect
          (let ((all (loop repeat n collect
                           (make-stupid))))
              #|
              (time
               (map nil (lambda (actor)
                          (send actor :nope))
                    all))
              |#
              ;; (inspect *actor-dict*)
              (time
               (progn
                 (map nil (lambda (actor)
                            (send actor :quit))
                      all)
                 (mp:process-wait "Waiting for TST finish"
                                  (lambda ()
                                    (= n *ct*)))))
              ))
        (setf *muffle-exits* old-muffle)))))

(tst #N|1_000_000|) ;; about 10 sec/1M Actors elapsed time
(make-actor :?? () ()
  (format t "~&*MUFFLE-EXITS* = ~A" *muffle-exits*)
  (terminate))
(kill-executives)
;; ---------------------------------------------------

(let ((x (make-actor :x (&rest msg)
             ()
             (um:dcase msg
               (:echo (arg)
                (print arg))
               (:who ()
                (print self))
               (:quit ()
                (terminate))))))
  (send x :echo :this)
  (send x :who)
  (send x :quit))

(let ((x (make-actor :x (&rest msg)
             (waiting-for-response
              after-response-fn
              (backlog (hcl:make-unlocked-queue)))
           (let ((main-fn (um:dlambda
                            (:echo (arg)
                             (print arg))
                            (:who ()
                             (print self))
                            (:quit ()
                             (terminate))
                            (:ask (from &rest question)
                             (declare (ignorable question))
                             (setf waiting-for-response (lw:mt-random (ash 1 32))
                                   after-response-fn    (lambda (ans)
                                                          (send from ans)))
                             (let ((from self)
                                   (serno waiting-for-response))
                               (spawn (lambda ()
                                        (send from :rpc-response serno 15)))))
                            )))
             (cond (waiting-for-response
                    (um:dcase msg
                      (:rpc-response (serno ans)
                       (cond ((eql serno waiting-for-response)
                              (setf waiting-for-response nil)
                              (funcall after-response-fn ans)
                              (loop for msg = (hcl:unlocked-queue-read backlog) do
                                    (apply main-fn msg)))
                             (t
                              (hcl:unlocked-queue-send backlog msg))
                             ))
                      (t (&rest _)
                         (declare (ignore _))
                         (hcl:unlocked-queue-send backlog msg))
                      ))
                   (t
                    (apply main-fn msg))
                   )))
         ))
  (send x :echo :This!)
  (send x :who)
  (send x :ask #'print 32)
  (send x :echo :That!)
  (sleep 1)
  (send x :quit))
|#
