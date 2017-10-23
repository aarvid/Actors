
(in-package #:actors-user)

(kill-executives)
(get-actors)

(make-actor #:test () ((x 15))
  (sleep 0.1)
  (pr (format nil "~&Self (1) = ~A" self))
  (wait (a b c)
      (list "ayy" "bee" "see") ;; <-- performed in foreign thead
    (pr "After WAIT"
        (format nil "~&Self (2) = ~A" self)
        (list a b c))
    (send self 32)
    (next-message (msg)
      (pr (format nil "~&Self (3) = ~A" self)
          msg)
      (pause
        (pr (format nil "~&Self (4) = ~A" self)
            (format nil "~&X = ~A" x)
            'done)
        (terminate)))))

(defun tst ()
  (make-actor #:test () ()
    (pr self)
    (wait (a b c)
        (list "ayy" "bee" "see") ;; <-- performed in foreign thead
      (pr self
          (list a b c))
      (send self 32)
      (next-message (msg)
        (pr msg)
        (pause
          (pr 'done)
          (terminate)))))) ))
(compile 'tst)
(tst)



(defun tst (n)
  ;; Ans: about 10 usec/ spawn-exit elapsed time
  (loop repeat n do
        (spawn (lambda ()))))


(let ()
  (dotimes (ix 1000)
    (spawn (lambda (ix) (pr ix)) ix)))
