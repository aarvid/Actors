
(in-package #:actors-base)

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
    (setf (actor-residence actor)        :terminated
          (actor-messages actor)         nil
          (actor-next-messages actor)    nil
          (actor-initial-behavior actor) nil
          (actor-next-behavior actor)    nil))
  ;; (queue-remove actor *actor-ready-queue*)
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
             
