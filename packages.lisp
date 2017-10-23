;; packages.lisp
;; DM/RAL  02/09
;; ------------------------------------------------------------------

(in-package :user)

(defpackage #:actors-macros
  (:use #:common-lisp)
  (:export
   #:gensym-like
   #:anaphor))

(defpackage #:actors-globals
  (:use #:common-lisp)
  (:export
   #:+nbr-execs+
   #:+max-pool+
   #:+heartbeat-interval+
   #:+maximum-age+

   #:*executive-processes*
   #:*executive-counter*
   #:*heartbeat-timer*
   #:*last-heartbeat*
   #:*muffle-exits*
   #:*current-actor*
   #:*actor-directory-manager*
   #:*shared-printer-actor*
   
   #:current-actor
   #:blind-print
   ))

(defpackage #:actors-queue
  (:use #:common-lisp)
  (:export
   #:*actor-ready-queue*
   #:add-queue
   #:queue-empty-p
   #:queue-empty
   #:pop-queue
   #:find-in-queue
   #:queue-remove
   #:make-lock
   #:with-lock
   ))

(defpackage #:actors-base
  (:use #:common-lisp
   #:actors-macros
   #:actors-globals
   #:actors-queue)
  (:export
   #:*current-actor*
   #:*muffle-exits*
   #:def-factory
   #:current-actor
   #:next-message
   #:next-time
   #:pause
   #:wait
   #:reset
   #:terminate
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
   #:pr

   #:with-actor-values
   #:actor-next-behavior
   #:actor-initial-behavior
   #:with-locked-actor
   #:ensure-executives
   #:actor
   #:actor-messages
   #:actor-next-messages
   #:actor-timeout-timer
   #:actor-name
   #:actor-residence
   #:actor-properties
   #:send-secondary
   #:add-actor
   
   #:get-actor-property
   #:set-actor-property
   
   #:defunc
   #:lambdac

   #:register-actor
   #:unregister-actor
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
   #:perform-with-timeout
   #:make-state-machine
   ))

(defpackage #:actors
  (:use #:common-lisp
   #:actors-macros
   #:actors-globals
   #:actors-queue
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
   #:next-message
   #:next-time
   #:pause
   #:wait
   #:reset
   #:terminate
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
   #:perform-with-timeout
   #:make-state-machine

   #:get-actor-property
   #:set-actor-property
   #:actor-name
   #:actor-properties
   
   #:pr
   #:defunc
   #:lambdac

   #:register-actor
   #:unregister-actor
   ))

(defpackage #:actors-user
  (:use #:common-lisp #:actors)
  (:export
   ))
