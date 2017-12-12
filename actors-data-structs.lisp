
(in-package #:actors-data-structs)

;; -------------------------------------------------------
;; Safe shared FIFO queues

(def-factory make-shared-queue (&rest msg)
    (items
     (tl (last items)))
  ;; use send, ask to retrieve
  (um:dcase msg
    
    (:add (item)
     (let ((cell (list item)))
       (if items
           (setf (cdr tl) cell
                 tl       cell)
         (setf items cell
               tl    cell))))
    
    (:pop (replyTo)
     (send replyTo (pop items))
     (unless items
       (setf tl nil)))
    
    (:empty-p (replyTo)
     (send replyTo (null items)))
    
    (:pop-all (replyTo)
     (setf tl nil)
     (send replyTo (shiftf items nil)))
    
    (:inspect ()
     (inspect items))
    ))

;; -------------------------------------------------------
;; Safe shared LIFO stacks

(def-factory make-shared-stack (&rest msg)
    (items)
  ;; use send, ask to retrieve
  (um:dcase msg
    
      (:add (item)
       (push item items))
      
      (:pop (replyTo)
       (send replyTo (pop items)))
      
      (:empty-p (replyTo)
       (send replyTo (null items)))
      
      (:pop-all (replyTo)
       (send replyTo (nreverse (shiftf items nil))))
      
      (:inspect ()
       (inspect items))
      ))

;; -----------------------------------------
;; Safe shared functional maps

(defun handle-shared-map (msg map)
  (um:dcase msg

    (:add (key val)
     (maps:add key val map))

    (:find (key replyTo)
     (send replyTo (maps:find key map))
     map)

    (:fold (fn accu replyTo)
     (send replyTo (maps:fold fn map accu))
     map)

    (:is-empty (replyTo)
     (send replyTo (maps:is-empty map))
     map)

    (:remove (key)
     (sets:remove key map))

    (:map (fn replyTo)
     (send replyTo (maps:map fn map))
     map)

    (:iter (fn)
     (maps:iter fn map)
     map)

    (:get (replyTo)
     (send replyTo map)
     (maps:empty))
    
    (:setf (new-map)
     new-map)

    (:empty ()
     (sets:empty))

    (:cardinal (replyTo)
     (send replyTo (sets:cardinal map))
     map)

    (:mapi (fn replyTo)
     (send replyTo (maps:mapi fn map))
     map)
    ))

(def-factory make-shared-map (&rest msg)
    ((map (sets:empty)))
    ;; use send, ask to retrieve
    (setf map (handle-shared-map msg map)))

#|
(let ((mm (make-shared-map)))
  (send mm :add :dog :cat)
  (send mm :add :cat :mouse)
  (send mm :add :mouse :man)
  (send mm :add :man :dog)
  (send mm :iter (lambda (k v) (pr (cons k v))))
  (prog1
      (pr
       (ask mm :fold  (lambda (k v a)
                        (cons (list k v) a))
            nil))
    (pr (ask mm :cardinal))
    ))
 |#

;; -----------------------------------------
;; Safe shared functional sets

(defun handle-shared-set (msg set)
  (um:dcase msg

    (:add (key)
     (sets:add key set))

    (:mem (key replyTo)
     (send replyTo (sets:mem key set))
     set)

    (:fold (fn accu replyTo)
     (send replyTo (sets:fold fn set accu))
     set)

    (:is-empty (replyTo)
     (send replyTo (sets:is-empty set))
     set)

    (:remove (key)
     (sets:remove key set))

    (:iter (fn)
     (sets:iter fn set)
     set)

    (:get (replyTo)
     (send replyTo (shiftf set (sets:empty)))
     set)
    
    (:setf (new-set)
     new-set)

    (:empty ()
     (sets:empty))

    (:cardinal (replyTo)
     (send replyTo (sets:cardinal set))
     set)

    (:some (pred replyTo)
     (send replyTo (sets:some pred set))
     set)

    (:!union (arg-set)
     (sets:union set arg-set))

    (:@union (arg-set replyTo)
     (send replyto (sets:union set arg-set))
     set)
    
    (:!intersection (arg-set)
     (sets:intersection set arg-set))

    (:@intersection (arg-set replyTo)
     (send replyTo (sets:intersection set arg-set))
     set)

    (:!s-x (arg-set)
     (sets:diff set arg-set))

    (:!x-s (arg-set)
     (sets:diff arg-set set))

    (:@s-x (arg-set replyTo)
     (send replyTo (sets:diff set arg-set))
     set)

    (:@x-s (arg-set replyTo)
     (send replyTo (sets:diff arg-set set))
     set)
    
    (:partition (pred replyTo)
     (send replyTo (sets:partition pred set))
     set)

    (:elements (replyTo)
     (send replyTo (sets:elements set))
     set)
    ))

(def-factory make-shared-set (&rest msg)
    ((set (sets:empty)))
  ;; use send, ask to retrieve
  (setf set (handle-shared-set msg set)))


;; -----------------------------------------------

(def-factory make-shared-hash-table (&rest msg)
    ((table (make-hash-table
             :single-thread t)))
  (um:dcase msg
    
    (:clear ()
     (clrhash table))
    
    (:add (key val)
     ;; this simply overwrites any existing entry
     (setf (gethash key table) val))
    
    (:remove (key)
     (remhash key table))
    
    (:get-all (replyTo)
     (let (pairs)
       (maphash (lambda (k v)
                  (push (cons k v) pairs))
                table)
       (send replyTo pairs)))
    
    (:find (name replyTo)
     (send replyTo (gethash name table)))

    (:find-or-add (name val replyTo)
     (send replyTo (or (gethash name table)
                       (setf (gethash name table) val))))
    ))

  