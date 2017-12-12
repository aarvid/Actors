;; packages.lisp
;; DM/RAL  02/09
;; ------------------------------------------------------------------

(in-package :user)

(defpackage #:actors-globals
  (:use #:common-lisp)
  (:export
   #:actor-termination-condition
   
   #:+nbr-execs+
   #:+max-pool+
   #:+heartbeat-interval+
   #:+maximum-age+
   #:+actor-termination+

   #:*executive-processes*
   #:*executive-counter*
   #:*heartbeat-timer*
   #:*last-heartbeat*
   #:*muffle-exits*
   #:*current-actor*
   #:*actor-ready-queue*
   #:*actor-directory-manager*
   #:*shared-printer-actor*
   
   #:current-actor
   #:blind-print
   ))

(defpackage #:actors-macros
  (:use #:common-lisp
   #:actors-globals)
  (:export
   #:gensym-like
   #:anaphor
   #:make-lock
   #:with-lock
   #:split-bindings
   #:in-eval-mode-p
   #:self-visible-p
   #:ensure-self-binding
   #:ensure-thread-eval))

(defpackage #:actors-base
  (:use #:common-lisp
   #:actors-macros
   #:actors-globals)
  (:export
   #:*current-actor*
   #:*muffle-exits*
   #:def-factory
   #:current-actor
   #:become
   #:wait
   #:reset
   #:next
   #:kill-executives
   #:send
   #:ask
   #:behav
   #:actor-alive-p
   #:find-actor
   #:find-actor-name
   #:get-actors
   #:remove-actor
   #:spawn
   #:make-actor
   #:pr

   #:with-actor-values
   #:actor-behavior
   #:with-locked-actor
   #:ensure-executives
   #:actor
   #:actor-behavior
   #:actor-messages
   #:actor-residence
   #:actor-properties
   #:actor-lambda-list
   
   #:send-secondary
   #:add-actor
   
   #:get-actor-property
   #:set-actor-property
   
   #:defunc
   #:lambdac

   #:register-actor
   #:unregister-actor

   #:add-to-ready-queue
   #:ready-queue-empty-p
   #:empty-ready-queue
   #:pop-ready-queue

   #:become
   ))

(defpackage #:actors-data-structs
  (:use #:common-lisp #:actors-base)
  (:export
   #:make-shared-queue
   #:make-shared-stack
   #:make-shared-map
   #:make-shared-set
   #:make-shared-hash-table
   ))

(defpackage #:actors-components
  (:use #:common-lisp #:actors-base)
  (:export
   #:make-printer-actor
   #:broadcast
   #:make-timestamper
   #:make-tee
   #:make-splay
   #:make-partitioner
   ))

(defpackage #:actors-machines
  (:use #:common-lisp
   #:actors-macros
   #:actors-base)
  (:export
   #:schedule-timeout
   #:unschedule-timeout
   #:recv
   #:become-recv
   #:make-state-machine
   ))

(defpackage #:actors
  (:use #:common-lisp
   #:actors-macros
   #:actors-globals
   #:actors-base
   #:actors-data-structs
   #:actors-components
   #:actors-machines)
  (:nicknames #:ac)
  (:export
   #:actor

   #:def-factory
   #:*current-actor*
   #:current-actor
   #:become
   #:wait
   #:reset
   #:kill-executives
   #:send
   #:ask
   #:behav
   #:actor-alive-p
   #:find-actor
   #:get-actors
   #:remove-actor
   #:spawn
   #:make-actor
   
   #:make-printer-actor
   #:make-shared-queue
   #:make-shared-stack
   #:make-shared-map
   #:make-shared-set
   #:make-shared-hash-table

   #:make-printer-actor
   #:broadcast
   #:make-timestamper
   #:make-tee
   #:make-splay
   #:make-partitioner

   #:schedule-timeout
   #:unschedule-timeout
   #:recv
   #:become-recv
   #:make-state-machine

   #:get-actor-property
   #:set-actor-property
   #:actor-lambda-list
   
   #:pr
   #:defunc
   #:lambdac

   #:register-actor
   #:unregister-actor

   #:become
   ))

(defpackage #:actors-user
  (:use #:common-lisp #:actors)
  (:export
   ))
