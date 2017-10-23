
(in-package :actors-base)

;; ------------------------------------------------------
;; Actor body macros for determining its next state. These require CPS
;; style coding.
;;
;; Notice that, like the anaphoric macros use of IT, these macros use
;; intentional capture of symbols SELF and ME. SELF refers to the
;; current Actor structure, while ME refers to the current Actor's
;; behavior function. Consistent conventions allow body code to be
;; written with confidence.

(defmacro next ()
  (let ((a!self (anaphor 'self)))
    `(throw :ACTOR ,a!self)))

(defun do-next-time (self behavior &optional nowait)
  ;; modify behavior for next message
  (with-locked-actor (self)
    (setf (actor-next-messages self) (unless nowait
                                       (actor-messages self))
          (actor-next-behavior self) behavior))
  (next))

(defmacro next-time (behavior &optional nowait)
  (let ((a!self (anaphor 'self)))
    `(do-next-time ,a!self ,behavior ,nowait)
    ))

(defmacro next-message (msg-args &body body)
  ;; await another message and then execute body
  ;; requires CPS style coding
  (let ((a!self (anaphor 'self)))
    `(next-time (lambda ,(cons a!self msg-args)
                  ,@body)
                ,@(unless msg-args
                    `(:no-wait)))
    ))

(editor:setup-indent "next" 1)

(defun do-reset (self)
  (do-next-time self (actor-initial-behavior self)))

(defmacro reset ()
  (let ((a!self (anaphor 'self)))
    ;; Set actor back to its initial behavior
    ;;
    ;; This doesn't make sense to use in an immediate actor (one with no
    ;; args)
    `(do-reset ,a!self)
    ))

(defmacro pause (&body body)
  ;; pause to allow other actors before performing body
  ;; requires CPS style
  `(next-message nil ,@body))

(defmacro terminate ()
  `(throw :ACTOR nil))

;; ----------------------------------------------------------------------------

(defun do-wait (self wait-fn behav-fn)
  ;; We must use a side channel mailbox here, since there is no
  ;; telling what may be in the mailbox of the actor. Regular message
  ;; passing is asynchronous and can be initiated from anywhere at any
  ;; time. We only want to respond to the results of the blocking code
  ;; thread. For that we need a specific private channel between only us.
  ;;
  ;; The wait-fn is spawned to a new Actor with immediate launch,
  ;; since it is arg-less. We do this instead of invoking a new OS
  ;; thread because it is highly likely that another ready Executive
  ;; in the pool can run the spawned actor, and if not, the executive
  ;; pool will be grown as needed.
  ;;
  ;; No need to lock the Actor because the fields being modified are
  ;; only modfied by the owning Actor when that Actor is running, and
  ;; only one instance of the Actor can be running at any time.
  ;;
  (let ((mbox (mp:make-mailbox)))
    (with-locked-actor (self)
      (setf (actor-next-messages self) mbox
            (actor-next-behavior self)
            (lambda (self msg)
              (apply behav-fn self (um.dispq:recover-ans-or-exn msg)))
            ))
    (spawn (lambda ()
             (send-secondary self (um.dispq:capture-ans-or-exn wait-fn))))
    (next)
    ))

(defmacro wait (msg-args wait-form &body body)
  (let ((a!self (anaphor 'self)))
    ;; wait on the wait-form, which should return msg-args before we
    ;; proceed with body. The wait-form is performed in a new thread
    ;;
    ;; msg-args must be a list
    ;; wait-form a single form
    ;; body any number of forms
    ;;
    ;; This actually arranges to spawn a new actor running the
    ;; wait-form, and packages up a continuation and returns
    ;; immediately to the Executive.  The wait-form sends a message to
    ;; our Actor, awakening it and running the body continuation. So
    ;; while we wait, we also yield to other ready Actors.
    ;;
    ;; In contrast, had we called a blocking action without using the
    ;; WAIT macro, our Executive thread will block. That's really okay
    ;; too, since the executive pool is automatically grown as needed.
    ;; But using WAIT is more efficient.
    ;;
    `(do-wait ,a!self
              (lambda ()
                ,wait-form)
              (lambda ,(cons a!self msg-args)
                ,@body))
    ))

(editor:setup-indent "wait" 2)

#|
 E.g.,
 
(labels ((me (...)
           (wait (a b c)
               (let* ((rd-a (read stream))
                      (rd-b (read stream))
                      (rd-c (read stream)))
                 (list rd-a rd-b rd-c)))
           (print a)
           (print b)
           (print c)
           (next-time #'me)) ;; <-- body must end in next-time, terminate
         ;; nothing more may follow, since it is beyond the CPS scode of body
         )
  ...)

;; --------------

(def-factory make-thingy-actor (arg)
    ()
  (pr arg)
  (wait (a b c)
      (list "ayy" "bee" "see") ;; <-- performed in foreign thead
    (pr (list a b c))
    (send self 32)
    (next-message (msg)
      (pr msg)
      (pause
        (pr 'done)
        (terminate)))))

(let ((x (make-thingy-actor)))
  (send x 15))

(make-actor #:test () ()
  (wait (a b c)
      (list "ayy" "bee" "see") ;; <-- performed in foreign thead
    (pr (list a b c))
    (send self 32)
    (next-message (msg)
      (pr msg)
      (pause
        (pr 'done)
        (terminate)))))

 |#

;; ----------------------------------------------------------------------------
;; Macro for creating actors with the behavior specified by body

(defmacro behav (args state &body body)
  ;; can only be used inside actor's body code to produce a new actor
  ;; state
  (let ((a!me   (anaphor 'me))
        (a!self (anaphor 'self)))
    `(let ,state
       (labels ((,a!me ,(cons a!self args)
                  ,@body
                  ,(if args
                       `(next)
                      `(terminate))))
         #',a!me))
    ))

(defun generate-actor (name args behav)
  ;; construct an Actor instance and add to the system
  (let ((actor (make-instance 'Actor
                              :name name
                              :lambda-list args
                              :behav behav)))
    (add-actor actor)
    actor))

(defmacro def-factory (name args state &body body)
  ;; state is like a LET binding
  ;; args is a list of args expected by the outer behavior.
  ;;
  ;; This macro builds a function that can be called to make multiple
  ;; instances of the same behavior (same kind of Actor), each with
  ;; their own private copy of internal state.
  ;;
  ;; within body you can refer to symbols ME = body code function,
  ;; SELF = current actor, and any of the symbols named in the binding
  ;; forms of the initial state
  (let ((a!name (anaphor 'name)))
    `(defun ,name (&key ,@state (,a!name (gensym-like :ACTOR-)))
       (generate-actor ,a!name ',args (behav ,args () ,@body)))
    ))

(defmacro make-actor (name args state &body body &environment env)
  (let ((inner `(generate-actor ',name ',args (behav ,args ,state ,@body))))
    (if (or (slot-value env 'compiler::compilation-env)
            (slot-value env 'compiler::fenv)
            (slot-value env 'compiler::venv))
        inner
      `(funcall (compile nil (lambda ()
                               ,inner))) )
    ))

(defun spawn (behavior &rest args)
  ;; impromptu creation of an Actor and immediate invocation with the
  ;; supplied args. This must specify a function, not an actor. Actors
  ;; are already spawned objects.
  (let ((actor (generate-actor (gensym-like :SPAWNED-)
                               (when args
                                 '(&rest args))
                               (lambda (self &rest args)
                                 (declare (ignore self))
                                 (apply behavior args)
                                 (terminate)))))
    (when args
      (apply #'send actor args))
    actor))

;; ----------------------------------------------------------------------
;; Helper macros DEFUNC and LAMBDAC
;;
;; If you ever write a defun or a lambda containing a MAKE-ACTOR,
;; then, if you expect to execute without having first compiled the
;; code, use DEFUNC in place of DEFUN, and LAMBDAC in place of LAMBDA
;;
;; Code containing MAKE-ACTOR needs to be compiled to assure proper
;; behavior at all times.
;;
;; If you always compile your code, then continue using DEFUN and
;; LAMBDA.

(defmacro defunc (name args &body body)
  `(progn
     (defun ,name ,args ,@body)
     (compile ',name)))

(defmacro lambdac (args &body body)
  `(funcall (compile nil (lambda ()
                           (lambda ,args
                             ,@body)))))

;; ---------------------------------------------------------------------

(editor:setup-indent "def-factory" 3)
(editor:setup-indent "behav"       2)
(editor:setup-indent "make-actor"  3)

#|
(defun tst () 
  (make-actor #:test () ()
    (pr self)
    (wait (a b c)
        (list "ayy" "bee" "see") ;; <-- performed in foreign thead
      (pr self)
      (pr (list a b c))
      (send self 32)
      (next-message (msg)
        (pr msg)
        (pause
          (pr 'done)
          (terminate))))))
(tst)

|#

