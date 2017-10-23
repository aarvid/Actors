
(in-package :actors-base)

#||#
;; LW Locks are more than twice as fast as spin-locks in this application
(defmacro make-lock (&rest args)
  `(mp:make-lock ,@args))

(defmacro with-lock ((lock) &body body)
  `(mp:with-lock (,lock)
     ,@body))
#||#
#|
(defun do-with-spinlock (lock-ref body-fn)
  (declare (cons lock-ref))
  (let ((me (mp:get-current-process)))
    (loop until (sys:compare-and-swap (car lock-ref) nil me))
    (unwind-protect
        (funcall body-fn)
      (sys:compare-and-swap (car lock-ref) me nil))))

(defun make-lock (&rest args)
  (declare (ignore args))
  (list nil))

(defmacro with-lock ((lock) &body body)
  `(do-with-spinlock ,lock
                     (lambda ()
                       ,@body)))
|#
;; --------------------------------------------------------
;; Actor state queue shared by all executives
;;
;; Three things are shared among OS threads: Actors, ready queue, and
;; waiting list. All three must use SMP locking to avoid race
;; conditions. Inside of actor behavior code, their local state access
;; is guranteed free from interference, since only one instance of an
;; actor exists, and it can only be on one of ready queue or wait
;; list, or running under one executive on one OS thread.
;;
;;                    / Wait List  
;;  Single Instance   \            (Realm of OS Threads and SMP)
;;   behavior code     \ Executives    
;;  (Green Threads)    /              Other Red-Thread code
;;                    / Ready Queue    (e.g. Listener REPL)
;;
;; SMP sharing is tricky, error prone, and requires careful thought in
;; coding. By contrast, the Actors internal universe is a joy to
;; program, without any need to think about this difficult stuff.
;;

(defstruct actor-queue
  hd tl              ;; head and tail of an Okasaki batched FIFO queue
  (lock (make-lock :name :actor-queue-lock))
  (sem  (mp:make-semaphore :count 0 :name :actor-queue)))

(defvar *actor-ready-queue* (make-actor-queue))

(defmethod add-queue (item (queue actor-queue))
  (with-accessors ((lock  actor-queue-lock)
                   (sem   actor-queue-sem)
                   (hd    actor-queue-hd)
                   (tl    actor-queue-tl)) queue
    (declare (list hd tl))
    (with-lock (lock)
      (if hd
          (push item tl)
        (push item hd))
      (mp:semaphore-release sem))
    item)) ;; like setf, return the item

(defmethod queue-empty-p ((queue actor-queue))
  (null (actor-queue-hd queue)))

(defmethod queue-empty ((queue actor-queue))
  ;; should only be called when it is known that no threads are
  ;; waiting on the semaphore, i.e., when there are no Executives
  ;; remaining.
  (with-accessors ((lock  actor-queue-lock)
                   (sem   actor-queue-sem)
                   (hd    actor-queue-hd)
                   (tl    actor-queue-tl)) queue
    (declare (list hd tl))
    (with-lock (lock)
      (setf hd  nil
            tl  nil
            sem (mp:make-semaphore :count 0 :name :actor-queue))
      )))

(defmethod %normalize-queue ((queue actor-queue))
  ;; internally used. must be contained within a lock on the queue
  (with-accessors ((hd    actor-queue-hd)
                   (tl    actor-queue-tl)) queue
    (declare (list hd tl))
    (unless hd
      (setf hd (nreverse tl)
            tl nil))
    ))
  
(defmethod pop-queue ((queue actor-queue))
  (with-accessors ((lock  actor-queue-lock)
                   (sem   actor-queue-sem)
                   (hd    actor-queue-hd)) queue
    (declare (list hd))
    (mp:semaphore-acquire sem)
    ;; pop-queue might return nil if an intervening remove happens
    ;; between the semaphore-acquire and the lock. Be prepared.
    (with-lock (lock)
      (when hd
        (prog1
            (pop hd)
          (%normalize-queue queue))
        ))
    ))

(defmethod find-in-queue (item (queue actor-queue) &key (key 'identity) (test 'eql))
  (with-accessors ((lock  actor-queue-lock)
                   (hd    actor-queue-hd)
                   (tl    actor-queue-tl)) queue
    (declare (list hd))
    (with-lock (lock)
      (when hd
        (or (find item hd :test test :key key)
            (find item tl :test test :key key))))
    ))

(defmethod queue-remove (actor (queue actor-queue))
  (with-accessors ((lock  actor-queue-lock)
                   (sem   actor-queue-sem)
                   (hd    actor-queue-hd)
                   (tl    actor-queue-tl)) queue
    (declare (list hd tl))
    (with-lock (lock)
      (when hd
        ;; Semaphore acquire might fail if an Executive did an acquire
        ;; before locking and there was only 1 item remaining, and we
        ;; got there to lock the queue before the Executive did...  We
        ;; will remove the last item, and the Executive will pop a
        ;; NIL.
        ;;
        (cond ((find actor hd :test #'eq)
               (mp:semaphore-acquire sem :timeout 0)
               (setf hd (delete actor hd :test #'eq)))

              ((find actor tl :test #'eq)
               (mp:semaphore-acquire sem :timeout 0)
               (setf tl (delete actor tl :test #'eq))) )
        (%normalize-queue queue)))
    ))

