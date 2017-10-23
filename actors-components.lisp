
(in-package #:actors-components)

#|
;; ----------------------------------------------------------------------------
;; Easy priting to repl from threads.

(defun pr (item)
  (print item *standard-output*)
  (format t "~%"))

;; ----------------------------------------------------------------------------
;; A printing actor
(def-factory make-printer-actor (item)
    ()
  (pr item))

;; give this one a (send xx 0) and see what happens...
(def-factory make-divide-actor (&rest args)
    ()
  (apply #'/ args))
|#
;; -----------------------------------------------
;; Mail Filtering for Selective Receive
;;
;; The convention will be that all Actors with configurable internal
;; state should respond to a message of the form:
;;
;;    (:control-command actor &rest cmds)
;;
;; where each of cmds is a message list indicating parameter and new
;; value. If an Actor sees a :control-command message where the actor
;; parameter is not EQ self, it should forward the whole message to
;; all other Actors to which it is connected.

(defun broadcast (actors &rest message)
  (map nil (lambda (actor)
             (apply #'send actor message))
       actors))

(def-factory make-timestamper (&rest msg)
    ((dest      #'lw:do-nothing)
     (timestamp #'get-universal-time))
  (um:dcase msg
    (:control-command (actor &rest cmds)
     (cond ((eq actor self)
            (map nil
                 (lambda (cmd)
                   (um:dcase cmd
                     (:set-dest (new-dest)
                      (setf dest new-dest))
                     (:set-timestamp (new-timestamp)
                      (setf timestamp new-timestamp))
                     ))
                 cmds))
           (t
            (apply #'send dest msg))
           ))
    (t (&rest _)
       (declare (ignore _))
       (funcall #'send dest `(,(funcall timestamp) ,msg)))
    ))
    
(def-factory make-tee (&rest msg)
    ((dest #'lw:do-nothing)
     (tap  #'lw:do-nothing))
  ;; make a tap in the pipeline
  (um:dcase msg
    (:control-command (actor &rest cmds)
     (cond ((eq actor self)
            (map nil
                 (lambda (cmd)
                   (um:dcase cmd
                     (:set-dest (new-dest)
                      (setf dest new-dest))
                     (:set-tap  (new-tap)
                      (setf tap new-tap))
                     ))
                 cmds))
           (t
            (apply #'broadcast `(,dest ,tap) msg))
           ))
    (t (&rest _)
       (declare (ignore _))
       (apply #'broadcast `(,dest ,tap) msg))
    ))

(def-factory make-splay (&rest msg)
    (dests)
  ;; could also have been constucted by a chain of tees, but this
  ;; should be more efficient
  (um:dcase msg
    (:control-command (actor &rest cmds)
     (cond ((eq actor self)
            (map nil
                 (lambda (cmd)
                   (um:dcase cmd
                     (:set-dests (new-dests)
                      (setf dests new-dests))
                     ))
                 cmds))
           (t
            (broadcast dests msg))
           ))
    (t (&rest _)
       (declare (ignore _))
       (broadcast dests msg))
    ))

(def-factory make-partitioner (&rest msg)
    ((pred    #'lw:true)
     (t-dest  #'lw:do-nothing)
     (f-dest  #'lw:do-nothing))
  ;; a 2-way router based on a predicate against the message
  (um:dcase msg
    (:control-command (actor &rest cmds)
     ;; cmds should be a list of command arg lists
     (cond ((eq actor self)
            (map nil
                 (lambda (cmd)
                   (um:dcase cmd
                     (:set-pred (new-pred)
                      (setf pred new-pred))
                     (:set-t-dest (new-t-dest)
                      (setf t-dest new-t-dest))
                     (:set-f-dest (new-f-dest)
                      (setf f-dest new-f-dest))
                     ))
                 cmds))
           (t
            (apply #'broadcast `(,t-dest ,f-dest) msg))
           ))
    (t (&rest _)
       (declare (ignore _))
       (apply #'send (if (apply pred msg)
                         t-dest
                       f-dest)
              msg))
    ))

;; ----------------------------------------------------------------

