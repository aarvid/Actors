;; Actors -- DM/RAL 10/17
;;
;; This package of code is a shameless hack, starting with the code in
;; CL-ACTORS, and heavily extending it to my needs.
;;
;; Actors are bodies of behavior code and associated private state
;; data that perform actions against arguments asynchronously sent to
;; them via non-blocking message sends.
;;
;; For this implementation, Actor behavior (should) perform
;; non-blocking sections of code against the message arguments before
;; returning a new next-execution state to the executive process, in
;; preparation for their next invocation.  Macro NEXT-TIME provides
;; this next-execution state back to the executive. Actors can
;; indicate alterations to their behavior for use on future message
;; sends, or offer back the same behavior.  Only one invocation of an
;; actor can occur at any one time, and so guarantees single-thread
;; access to private state data.
;;
;; [Note: There can be no enforcement of non-blocking protocol, but
;; macros NEXT, PAUSE, and WAIT can help facilitate adherence to
;; non-blocking code.
;;
;; But compute bound actors could still hog the system, even if they
;; had been carefully crafted to avoid blocking behavior on I/O.
;; Hence, see below, where we implement a heartbeat heuristic with a
;; watchdog timer, and if all executives in the pool appear to be tied
;; up, then a new executive is added to the pool.  Beyond some limit,
;; this accumulation ceases with an error signal.]
;;
;; Macro DEF-FACTORY defines an actor factory function, with initial
;; state data bindings, and behavior code, for a particular class of
;; actor. Calling a defined factory function actually constructs an
;; Actor structure, gives the caller a chance to override initial
;; private binding values, and enters the newly constucted Actor into
;; the executive queue system.
;;
;; This package implements a system of green threads to run actors,
;; [hence, the desire for non-blocking behavior] managed by a pool of
;; executives operating as red threads in native OS threads. We strive
;; for one executive per CPU core, but affinity cannot be assigned.
;;
;; Execitives run whenever a ready actor is available. The executives
;; will block waiting for ready actors, hence, the need for them to be
;; red threads. Once a ready actor is obtained, the actor's behavior
;; code runs on the same thread as the executive, blocking the
;; executive from any further action until the actor returns its next
;; run-state.
;;
;; Extant Actors are placed into one of two queues - a wait queue, or
;; a ready queue. The executives remove actors from the ready queue
;; for execution of their behavior code, then return them to either
;; the ready queue if more messages await, or to the wait queue.  A
;; message send removes an actor from the wait queue and adds it to
;; the ready queue.
;;
;; Queues are managed in FIFO order so that fair round-robin
;; scheduling occurs. There are no priority distinctions among actors.
;; Actors in the ready queue can be executed by any available
;; executive thread in the executive pool.
;;
;; The queues are SMP-safe shared queues among all executive threads,
;; using CAS spinlocks for queue access and modification.
;;
;;  (Wait Queue)
;;       |<-- message send
;;       |
;;       |        Executive - run actor code / wait for ready
;;       v       /
;;  (Ready Queue) -- Executive - run actor code / wait for ready
;;               \
;;                Executive - run actor code / wait for ready
;;
;; Actors cannot depend on running in any particular OS thread, but
;; their behavior code can be assumed to operate without preemption
;; from another instance of the same actor. An actor can only be alive
;; on one thread at any moment, and will run to completion in the same
;; thread in which it fired. Internal state is SMP safe from
;; alteration by other code running in parallel on another OS thread.
;; Reentrant behavior code is unnecessary.
;;
;; Actor behaviors must always return the actor back to the
;; executives.  Their state indicates the mailbox on which it is
;; awaiting more messages, and the next behavior code to run when a
;; message arrives.  Macro NEXT-TIME, as the last evaluated form
;; provides this information back to the executive.
;;
;; Returning a null mailbox to the executive indicates a desire only
;; to pause, to allow other actors a chance to run, but the returning
;; actor remains ready for execution afterward. This is arranged by
;; use of macro PAUSE.
;;
;; Actor behaviors should be written in wait-free manner, or use one
;; of the macros WAIT, PAUSE, NEXT-MESSAGE, RESET, or NEXT, as the last form
;; executed, to yield back to the executive. The actor will be
;; continued in the follow body code:
;;
;;    -- On receipt of the next message, for macro NEXT-MESSAGE and NEXT,
;;        (NEXT retains the existing behavior,
;;           while NEXT-MESSAGE specifies new behavior)
;;
;;    -- The next available run slot from the executive, for macro PAUSE,
;;
;;    -- The completion of blocking code, for macro WAIT.
;;
;; An actor that no longer wishes to participate should end with the
;; TERMINATE macro. Actors can also be forcibly terminated with
;; function REMOVE-ACTOR, although if the actor is presently runnng it
;; will continue running until it returns to the executive, after
;; which it will remain unschedulable.
;;
;; WAIT is used for blocking I/O, in which case the blocking code is
;; spawned into another OS red thread for execution. That blocking
;; code should return a value that the executive will message send to
;; the waiting actor. If any errors occur in the blocking code they
;; will be reflected back to the calling actor, instead of the
;; expected message arguments.
;;
;; If an actor bombs out, the executive will log the error and
;; terminate the actor. A terminated actor no longer participates with
;; the ready & waiting queues, and its mailbox is zapped to prevent
;; message sends to the actor from succeeding. This might cause a
;; cascade of other actors to bomb out.
;;
;; Message sends can refer to target actors by actual reference to an
;; Actor structure, or by name, for a named actor. Direct references
;; avoid the slowdown caused by a search of the queues for the
;; associated actor. Obviously, actors should be given unique names if
;; the named send protocol is chosen. Actors should be named with
;; strings or symbols.
;;
;; Communication with actors is facilitated by function GET, which
;; first sends a message, then awaits a response to a privately held
;; replyTo mailbox. By convention, in the actor behavior code, the
;; replyTo mailbox is always the last given argument in a message. The
;; communication back to the message sender occurs by SEND to that
;; replyTo argument. There be trouble if GET is used on a message to
;; which the actor doesn't respond. While SEND is non-blocking, the
;; mailbox-read is.
;;
;; SEND is non-blocking in both directions. SEND is overloaded as a
;; method to further support non-blocking sending of messages through
;; Reppy Channels, mp:mailboxes, and mp:procedures with
;; proc-mailboxes, in addition to sending to actors either directly or
;; by name lookup.
;;
;; Doug Hoyt's DLAMBDA is an excellent mechanism for producing actors
;; which provide shared data structures, which the Actor system
;; guarantees as single thread access/modify to private state data,
;; free from meddlesome interference from other threads. See below for
;; SHARED-QUEUE, SHARED-STACK, SHARED-MAP, and SHARED-SET.  No need
;; for locks and other SMP coordination mechanisms for shared memory
;; access to persistent actor private state data.
;;
;; Persistence, here, refers to data that retains memory between
;; invocatons of the same actor instance. Once terminated, an actor's
;; private persistent state data also becomes inaccessible. This
;; single thread freedom won't be true for shared global data, which
;; still requires SMP coordination among threads.
;;
;; ---------------------------------------------------------------

(in-package #:actors)

;; --------------------------------------------------------------------

(defclass actor ()
  ((name
    :initarg :name
    :initform (error ":name must be specified")
    :accessor actor-name
    :documentation "Hold the name of actor")
   ;; while all Actor instance are named, the name can be anything at
   ;; all. However, if you want your Actor to be locatable by the
   ;; Actor Directory Service, then the name must be either a String,
   ;; or an interned Symbol. All names are searched for by upcasing
   ;; their string form, so "this" and :THIS are the same thing as far
   ;; as the directory is concerned. An uninterned symbol name like
   ;; #:THIS will not be entered into the Actor Directory.
   
   (lambda-list
    :initarg :lambda-list
    :initform (error ":lambda-list must be specified")
    :accessor actor-lambda-list
    :documentation "Hold the lambda-list of actor")
   ;; this only hold the lambda list at the time of Actor creation.
   ;; Use of PAUSE, NEXT-MESSAGE, NEXT-TIME, WAIT, etc. can
   ;; dynamically alter the true lambda list of the Actor.

   (messages
    :initform (mp:make-mailbox)
    :accessor actor-messages
    :documentation "Message stream sent to actor")
   ;; the main communications mailbox for use by SEND

   (initial-behavior
    :accessor actor-initial-behavior
    :initarg :behav)
   ;; initial-behavior holds the initial behavior of the Actor
   ;; we retain this information for easy RESET back to initial state

   (next-behavior
    :accessor actor-next-behavior)
   ;; next-behavior holds the behavior code to be run at the next
   ;; invocation. It starts out with initial-behavior, but gets
   ;; modified by NEXT-TIME, PAUSE, WAIT, and can be reset to the
   ;; initial behavior with RESET.
   
   (next-messages
    :accessor actor-next-messages)
   ;; next-messages holds a reference to the mailbox from which the
   ;; next messages are anticipated. This is normally a copy of the
   ;; MESSAGES slot value, but could be a reference to another private
   ;; mailbox for sidechannel comms with blocking actors (WAIT), or
   ;; NIL to indicate not waiting at all.

   (residence
    :accessor actor-residence
    :initform nil)
   ;; residence records which queue (ready/waiting) in which the actor
   ;; resides, or nil if not on any queue. Checking this slot is much
   ;; faster than searching in the ready-queue.
   ;;
   ;; (N.B. there is no longer a wait-queue. That was too much of a
   ;; slowdown in timing benchmarks. Non-ready Actors are simply NIL.
   ;; Terminated Actors are :TERMINATED. Ready Actors point to the
   ;; ready-queue)

   (timeout-timer
    :accessor actor-timeout-timer
    :initform nil)
   ;; the timeout-timer supports the use of SCHEDULE-TIMEOUT against an actor
   
   (lock
    :accessor actor-lock
    :initform (make-lock :name :Actor-lock))
   ;; in an SMP environment, me must use locking to gain unfettered
   ;; access to consistent state

   (properties
    :accessor actor-properties
    :initform nil
    :initarg  :properties)
   ;; a general purpose properties list for use by the Actor itself.
   ;; Since this slot is never accessed anywhere (yet) and it is
   ;; intended for use by the Actor when it is running, there should
   ;; be no need for locked access to this slot.
   ;;
   ;; Local state can be kept either in closed over lexical bindings
   ;; in the behavior closures, or in this list. Access to state is
   ;; probably faster with lexical bindings in the closure. But state
   ;; kept here will be more easily inspected. It's up to you...
   ))

(defmethod initialize-instance :after ((actor actor) &key &allow-other-keys)
  (setf (actor-next-behavior actor) (actor-initial-behavior actor)
        (actor-next-messages actor) (when (actor-lambda-list actor)
                                      (actor-messages actor)))
  (register-actor actor))

(defmethod print-object ((actor actor) out-stream)
  (format out-stream "#<ACTOR ~A>" (actor-name actor)))

(defmethod get-actor-property ((actor actor) key &optional default)
  (getf (actor-properties actor) key default))

(defmethod set-actor-property ((actor actor) key val)
  (setf (getf (actor-properties actor) key) val))

(defsetf get-actor-property set-actor-property)

;; ----------------------------------------------------------

(defmacro with-locked-actor ((actor &rest args) &body body)
  `(with-lock ((actor-lock ,actor) ,@args)
     ,@body))

(defmacro with-actor-values (bindings actor &body body)
  ;; get a consistent collection of actor slot values
  (let ((syms      (mapcar #'car bindings))
        (accessors (mapcar #'cadr bindings))
        (g!actor   (gensym-like :actor-)))
    `(let ((,g!actor ,actor))
       (multiple-value-bind ,syms
           (with-locked-actor (,g!actor)
             (values ,@(mapcar #`(,a1 ,g!actor) accessors)))
         ,@body))
    ))

;; ----------------------------------------------------------
;; Actors directory -- only for Actors with symbol names or string
;; names.
;;
;; This really ought to be an Actor-based manager! The directory is a
;; non-essential service during Actor base startup, so we will make it
;; an Actor-based service after all the base code is in place.

(defun directory-manager-p ()
  (typep *actor-directory-manager* 'Actor))

        ;;; =========== ;;;

(defmethod acceptable-key (name)
  nil)

(defmethod acceptable-key ((name (eql nil)))
  nil)

(defmethod acceptable-key ((name symbol))
  (and (symbol-package name)
       (acceptable-key (string name))))

(defmethod acceptable-key ((name string))
  (string-upcase name))

(defmethod acceptable-key ((actor actor))
  (acceptable-key (actor-name actor)))

        ;;; =========== ;;;

(defmethod register-actor ((actor actor))
  (when (acceptable-key actor)
    (send *actor-directory-manager* :register actor)))
  
(defmethod unregister-actor ((actor actor))
  (when (acceptable-key actor)
    (send *actor-directory-manager* :unregister actor)))

(defun get-recorded-actors ()
  (when (directory-manager-p)
    (ask *actor-directory-manager* :get-all)))

(defun find-actor-in-directory (name)
  (when (and (directory-manager-p)
             (acceptable-key name))
    (ask *actor-directory-manager* :find name)))

(defun clear-actor-directory ()
  (send *actor-directory-manager* :clear))

(defun quit-actor-directory-manager ()
  (send (shiftf *actor-directory-manager* #'lw:do-nothing) :quit))

;; --------------------------------------------------------
;; Shared printer driver... another instance of something better
;; placed into an Actor

(defun pr (&rest things-to-print)
  (apply #'send *shared-printer-actor* :print things-to-print))

;; --------------------------------------------------------------------
;; External communication with an Actor

(defun add-to-ready-queue (actor)
  ;; actor should already be locked
  (setf (actor-residence actor) *actor-ready-queue*)
  (add-queue actor *actor-ready-queue*)
  (unless *executive-processes*
    (ensure-executives)))
  
(defun send-through-actor-mbox (actor mbox message)
  ;; called from inside of actor lock
  (when mbox
    (mp:mailbox-send mbox message)
    (when (and (null (actor-residence actor)) ;; not already on ready queue, nor :terminated
               (eq mbox (actor-next-messages actor))) ;; did we send to what it is expecting?
      (add-to-ready-queue actor)))
  (values))

(defmethod send (dest &rest message)
  ;; default to preserve semantics of quiet and no-hang sending
  (declare (ignore dest message))
  (values))

(defmethod send ((actor actor) &rest message)
  ;; send a message to an actor
  (with-locked-actor (actor)
    (send-through-actor-mbox actor (actor-messages actor) message)))

(defmethod send-secondary ((actor actor) &rest message)
  ;; used to support side channel comms with WAIT blocking code
  (with-locked-actor (actor)
    (send-through-actor-mbox actor (actor-next-messages actor) message)))

(defmethod send ((mbox mp:mailbox) &rest message)
  ;; used by actor code to reply to ask
  (mp:mailbox-send mbox message)
  (values))

(defmethod send ((ch rch:channel) &rest message)
  ;; maybe useful??
  (rch:poke ch message)
  (values))

(defmethod send ((fn function) &rest message)
  (apply fn message))

(defmethod send ((name (eql nil)) &rest message)
  ;; handle the special symbol NIL to avoid an infinite loop
  (declare (ignore name message))
  (values))

(defmethod send ((name symbol) &rest message)
  ;; this is slower, but what the heck...
  (apply #'send (find-actor name) message))

(defmethod send ((name string) &rest message)
  ;; this is slower, but what the heck...
  (apply #'send (find-actor name) message))

(defun ask (actor &rest message)
  ;; used to query an actor written in dlambda style
  ;;
  ;; should be wrapped with WAIT, if called from within an actor
  ;; behavior when the service might take a while to respond.
  (let ((mb (mp:make-mailbox)))
    (apply #'send actor `(,@message ,mb))
    (values-list (mp:mailbox-read mb))))

;; ------------------------------------------------------------
;; Internal routines for constructing an Actor and enabling it

(defun add-actor (actor)
  ;; internal, used by make-actor, executive process
  ;; adds the actor to the ready / wait queue
  (with-locked-actor (actor)
    ;; now that we're locked, check again to be sure...
    (cond ((actor-alive-p actor)
           (cond ((let ((mbox (actor-next-messages actor)))
                    (or (null mbox)
                        (mp:mailbox-not-empty-p mbox)))
                  ;; A null mbox results from a simple pause. Otherwise it is
                  ;; the mailbox to which some message might have been sent
                  (add-to-ready-queue actor))
                 
                 (t
                  (setf (actor-residence actor) nil))
                 ))
          (t
           (remove-actor actor))
          )))

;; --------------------------------------------------------
;; Queue introspection

(defun actor-alive-p (actor)
  (and (actor-next-behavior actor)
       actor))
    
(defun get-actors ()
  (get-recorded-actors))

(defmethod remove-actor ((actor actor))
  ;; Be careful with this... the actor might actually be pending with
  ;; some legitimate and important work!
  (with-locked-actor (actor)
    (setf (actor-residence actor)      :terminated
          (actor-messages actor)       nil
          (actor-next-messages actor)  nil
          (actor-next-behavior actor)  nil))
  (queue-remove actor *actor-ready-queue*)
  (unregister-actor actor))

(defmethod remove-actor (name)
  (remove-actor (find-actor name)))

(defmethod find-actor ((actor actor))
  (actor-alive-p actor))

(defun find-live-actor-in-directory (name)
  (let ((actor (find-actor-in-directory name)))
    (when actor
      (cond ((actor-alive-p actor)
             actor)
            (t
             (remove-actor actor)
             nil)))
    ))

(defmethod find-actor ((name string))
  (find-live-actor-in-directory name))

(defmethod find-actor ((name symbol))
  (find-live-actor-in-directory name))
             
