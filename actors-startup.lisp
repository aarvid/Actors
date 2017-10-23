
(in-package :actors)

;; ----------------------------------------------------------------------------

(defun install-actor-directory ()
  (unless (directory-manager-p)
    (setf *actor-directory-manager*
          (make-actor :Actor-directory (&rest msg)
              ((directory (make-hash-table :test 'equal)))
            (labels ((clean-up ()
                       (setf *actor-directory-manager* #'lw:do-nothing)
                       (terminate))
                     (get-actor-key (actor)
                       (when (typep actor 'Actor)
                         (acceptable-key actor))))
              (handler-case
                  (um:dcase msg
                    
                    (:clear ()
                     (clrhash directory))
                    
                    (:register (actor)
                     ;; this simply overwrites any existing entry with actor
                     (um:when-let (key (get-actor-key actor))
                       (setf (gethash key directory) actor)))
                     
                    (:unregister (actor)
                     (um:when-let (key (get-actor-key actor))
                       (remhash key directory)))
                    
                    (:get-all (replyTo)
                     (let (actors)
                       (maphash (lambda (k v)
                                  (declare (ignore k))
                                  (push v actors))
                                directory)
                       (send replyTo actors)))
                    
                    (:find (name replyTo)
                     (send replyTo (um:when-let (key (acceptable-key name))
                                     (gethash key directory))))
                    
                    (:quit ()
                     (clean-up))
                    )

                (error (err)
                  (clean-up))
                ))))
    (register-actor *actor-directory-manager*)
    (pr "Actor Directory created...")))

(defun install-actor-printer ()
  (setf *shared-printer-actor*
        (make-actor :Shared-Printer (&rest msg)
            ()
          (um:dcase msg
            (:print (&rest things-to-print)
             (dolist (item things-to-print)
               (print item)))

            (:quit ()
             (setf *shared-printer-actor* #'blind-print)
             (terminate))
            ))
        ))

(defun install-actor-system (&rest ignored)
  (declare (ignore ignored))
  (install-actor-directory)
  (install-actor-printer))

#||#
#+:LISPWORKS
(let ((lw:*handle-existing-action-in-action-list* '(:silent :skip)))
  
  (lw:define-action "Initialize LispWorks Tools"
                    "Start up Actors"
                    'install-actor-system
                    :after "Run the environment start up functions"
                    :once))
#||#
