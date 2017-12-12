
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

        ;;; =========== ;;;

(defmethod register-actor ((actor actor) name)
  (when (acceptable-key name)
    (send *actor-directory-manager* :register actor name)))
  
(defun unregister-actor (name-or-actor)
  (send *actor-directory-manager* :unregister name-or-actor))

(defun get-recorded-actors ()
  (when (directory-manager-p)
    (ask *actor-directory-manager* :get-all)))

(defun find-actor-in-directory (name)
  (when (and (directory-manager-p)
             (acceptable-key name))
    (ask *actor-directory-manager* :find name)))

(defmethod find-actor-name ((actor actor))
  (when (directory-manager-p)
    (ask *actor-directory-manager* :reverse-lookup actor)))

;; --------------------------------------------------------
;; Shared printer driver... another instance of something better
;; placed into an Actor

(defun pr (&rest things-to-print)
  (apply #'send *shared-printer-actor* :print things-to-print))

;; --------------------------------------------------------------------
;; External communication with an Actor

(defmethod send (dest &rest message)
  ;; default to preserve semantics of quiet and no-hang sending
  (declare (ignore dest message))
  (values))

(defmethod send ((actor actor) &rest message)
  ;; send a message to an actor
    (mp:mailbox-send (actor-messages actor) message)
    (add-to-ready-queue actor)
    (values))

(defmethod send ((mbox mp:mailbox) &rest message)
  ;; used by actor code to reply to ask
  (mp:mailbox-send mbox message)
  (values))

(defmethod send ((ch rch:channel) &rest message)
  ;; maybe useful??
  (rch:poke ch message)
  (values))

(defmethod send ((fn function) &rest message)
  (apply fn message)
  (values))

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

(defun actor-alive-p (actor)
  (and (actor-behavior actor)
       actor))
    
(defun add-actor (actor)
  ;; internal, used by make-actor, executive process
  ;; may add the actor to the ready queue
  (mark-not-in-queue actor)
  (when (mp:mailbox-not-empty-p (actor-messages actor))
    (add-to-ready-queue actor)))

;; --------------------------------------------------------
;; Directory Introspection

(defun get-actors ()
  (get-recorded-actors))

(defmethod find-actor ((actor actor))
  (actor-alive-p actor))

(defun find-live-actor-in-directory (name)
  (find-actor (find-actor-in-directory name)))

(defmethod find-actor ((name string))
  (find-live-actor-in-directory name))

(defmethod find-actor ((name symbol))
  (find-live-actor-in-directory name))

(defmethod find-actor ((actor (eql nil)))
  nil)

