;;;; -*- Mode: Lisp; Syntax: ANSI-Common-Lisp; Base: 10; indent-tabs-mode: nil -*-

;;;; This file is part of Sheeple

;;;; messages.lisp
;;;;
;;;; Message metasheep, message definition and management
;;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(in-package :sheeple)

#+sheeple3.1
(define-bound-variable =standard-message=)
#+sheeple3.1
(defparameter the-std-message-form '(defproto =standard-message= ()
                                     ((name nil :accessor nil)
                                      (lambda-list nil :accessor nil)
                                      (replies nil :accessor nil)
                                      (memo-vector (make-vector 40) :accessor nil)
                                      (arg-info (make-arg-info) :accessor nil))))

#+sheeple3.1
(defun %make-message (&key name lambda-list replies (documentation ""))
  (defsheep (=standard-message=) ((name name) (lambda-list lambda-list)
                                  (replies replies)
                                  (memo-vector (make-vector 40))
                                  (arg-info (make-arg-info)))))

;;;
;;; Message object
;;;
;;; - Messages are the Sheeple equivalent of a generic function. Unlike CLOS' generic functions,
;;;   though, the role messages take is smaller. Messages themselves are fairly blind to the dispatch
;;;   mechanism. As far as the user interface goes, they're used as a sort of interface definition.
;;;   The main role they take on (visible to the user) is to maintain lambda-list congruence across
;;;   different replies (sheeple-speak for methods). Sheeple messages follow the same rules as
;;;   CLOS generic functions use for lambda-list congruence, as outlined in
;;;   http://www.lispworks.com/documentation/HyperSpec/Body/07_fd.htm
;;;
;;;   Design-wise, this is a bit of an annoyance, since it means Replies aren't entirely independent.
;;;   I made the decision many tags ago, though, that maintaining CLOS-style lambda-list congruence
;;;   was worth the price. As it turns out, there were other convenient reasons to have a global
;;;   'registry' of replies: All existing replies can be listed for the user, an obvious interface
;;;   can be defined, and the message object can be used as an obvious place to store the cached
;;;   dispatch information.
(defstruct (message (:constructor %make-message)
                    (:predicate messagep)
                    (:print-object
                     (lambda (message stream)
                       (print-unreadable-object (message stream :identity t)
                         (format stream "Message: ~a" (message-name message))))))
  name lambda-list replies documentation
  (dispatch-cache (make-dispatch-cache))
  (arg-info (make-arg-info)))

;;;
;;; Message Documentation
;;;

(defmethod documentation ((x message) (doc-type (eql 't)))
  (message-documentation x))

(defmethod documentation ((x symbol) (doc-type (eql 'message)))
  (documentation (find-message x nil) t))

(defmethod (setf documentation) (new-value (x message) (doc-type (eql 't)))
  (setf (message-documentation x) new-value))

(defmethod (setf documentation) (new-value (x symbol) (doc-type (eql 'message)))
  (setf (documentation (find-message x nil) t) new-value))

;;;
;;; Message definition
;;;

(defvar *message-table* (make-hash-table :test 'equal)
  "Hashtable for storing message objects.") ; EQUAL test accomodates setf messages

(defun message-table-p (table)
  ;; This is sort of stupid, but I'm sort of hoping it's going to help me make the interface more
  ;; generic, in case I ever want to change what the message table is actually represented as.
  (hash-table-p table))

;; We define these two as internal first, so we don't export (setf find-message)
(declaim (inline %find-message))
(defun %find-message (name)
  (values (gethash name *message-table*)))
(defun (setf %find-message) (new-value name)
  (setf (gethash name *message-table*) new-value))

(defun forget-message (name)
  (remhash name *message-table*))

(defun forget-all-messages ()
  (clrhash *message-table*) t)

(defun find-message (name &optional (errorp t))
  "Finds a message object named NAME in `*MESSAGE-TABLE*'.
Raises an error if no message is found, unless ERRORP is NIL."
  (or (%find-message name)
      (when errorp (error 'no-such-message :message-name name))))

;;;
;;; Global dispatch cache
;;;
;;; - We hold a global cache for each message, which is filled as different objects are dispatched on.
;;;   This allows fairly quick lookup of applicable replies when a particular message is called over
;;;   and over on the same arguments.
(defparameter *dispatch-cache-size* 40
  "This variable determines the size of messages' dispatch caches. The bigger the number, the
more entries the cache will be able to hold, but the slower lookup will be.")

(defun make-dispatch-cache ()
  (make-vector *dispatch-cache-size*))
(defun dispatch-cache-p (x)
  (vectorp x))

(defun make-dispatch-cache-entry (args replies)
  ;; Since args points to actual arguments for a message, we wrap it in a weak pointer to make sure
  ;; the args can be GCd. Otherwise, calling any message on a number of arguments will make those
  ;; arguments stick around indefinitely.
  (cons (make-weak-pointer args) replies))
(defun dispatch-cache-entry-p (x)
  (and (consp x) (weak-pointer-p (car x)) (listp (cdr x))))

(defun cache-entry-args (entry)
  (weak-pointer-value (car entry)))
(defun cache-entry-replies (entry)
  (cdr entry))

(defun add-entry-to-message (message applicable-replies args index-if-full)
  (let ((dispatch-cache (message-dispatch-cache message))
        (entry (make-dispatch-cache-entry args applicable-replies)))
    ;; We first try to make sure a cache is filled up. If it is, we insert the new entry
    ;; into INDEX-IF-FULL. This is a bit leaky, and should probably be improved.
    (aif (position 0 dispatch-cache)
         (setf (svref dispatch-cache it) entry)
         (setf (svref dispatch-cache index-if-full) entry))))

(defun clear-dispatch-cache (message)
  (setf (message-dispatch-cache message) (make-dispatch-cache)))

(defun clear-all-message-caches ()
  (maphash-values 'clear-memo-table *message-table*))

;;;
;;; Arg info
;;;
;;; - Arg info objects and the operations on them are meant to check that Message/Reply lambda-lists
;;;   comply with http://www.lispworks.com/documentation/HyperSpec/Body/07_fd.htm
;;;
;;; Most of this code is taken from SBCL, and I really don't understand exactly how it works yet.
;;;   -zkat
(defstruct arg-info
  (lambda-list :no-lambda-list)
  number-required number-optional key/rest-p
  ;; nil: no &KEY or &REST allowed
  ;; (k1 k2 ..): Each reply must accept these &KEY arguments.
  ;; T: must have &KEY or &REST
  keys)

(defun check-reply-arg-info (msg arg-info reply)
  (multiple-value-bind (nreq nopt keysp restp allow-other-keys-p keywords)
      (analyze-lambda-list (reply-lambda-list reply))
    (flet ((lose (string &rest args)
             (error 'sheeple-error
                    :format-control "~@<The reply~2I~_~S~I~_ can't be added~
                                     to the message~2I~_~S;~I~_ because ~?~:>"
                    :format-args (list reply msg string args)))
           (comparison-description (x y)
             (if (> x y) "more" "fewer")))
      (with-accessors ((msg-nreq       arg-info-number-required)
                       (msg-nopt       arg-info-number-optional)
                       (msg-key/rest-p arg-info-key/rest-p)
                       (msg-keywords   arg-info-keys))
          arg-info
        (cond ((not (= nreq msg-nreq))
               (lose "the reply has ~A required arguments than the message."
                     (comparison-description nreq msg-nreq)))
              ((not (= nopt msg-nopt))
               (lose "the reply has ~A optional arguments than the message."
                     (comparison-description nopt msg-nopt)))
              ((not (eq (or keysp restp) msg-key/rest-p))
               (lose "the reply and message differ in whether they accept~_~
                      &REST or &KEY arguments."))
              ((and (consp msg-keywords)
                    (not (or (and restp (not keysp)) allow-other-keys-p
                             (every (rcurry 'memq keywords) msg-keywords))))
               (lose "the reply does not accept each of the &KEY arguments~2I~_~S."
                     msg-keywords))
              (t t))))))

(defun set-arg-info (message &key new-reply (lambda-list nil lambda-list-p))
  (let* ((arg-info (message-arg-info message))
         (replies (message-replies message))
         (firstp (and new-reply (null (cdr replies)))))
    (when (and (not lambda-list-p) replies)
      (setf lambda-list (message-lambda-list message)))
    (when (or lambda-list-p
              (and firstp
                   (eq (arg-info-lambda-list arg-info) :no-lambda-list)))
      (multiple-value-bind (nreq nopt keysp restp allow-other-keys-p keywords)
          (analyze-lambda-list lambda-list)
        (unless (or (not replies) firstp
                    (and (= nreq (arg-info-number-required arg-info))
                         (= nopt (arg-info-number-optional arg-info))
                         (eq (or keysp restp) (arg-info-key/rest-p arg-info))))
          (error 'reply-lambda-list-conflict :lambda-list lambda-list :message message))
        (setf (arg-info-lambda-list arg-info) (if lambda-list-p
                                                  lambda-list
                                                  (create-msg-lambda-list lambda-list))
              (arg-info-number-required arg-info) nreq
              (arg-info-number-optional arg-info) nopt
              (arg-info-key/rest-p arg-info) (not (null (or keysp restp)))
              (arg-info-keys arg-info) (if lambda-list-p
                                           (if allow-other-keys-p t keywords)
                                           (arg-info-key/rest-p arg-info)))))
    (when new-reply (check-reply-arg-info message arg-info new-reply))
    arg-info))

(defun check-message-lambda-list (lambda-list)
  (flet ((check-no-defaults (list)
           (awhen (find-if (complement (rcurry 'typep '(or symbol (cons * null)))) list)
             (error 'message-lambda-list-error :arg it :lambda-list lambda-list))))
    (multiple-value-bind (required optional restp rest keyp keys aok auxp)
        (parse-lambda-list lambda-list)
      (declare (ignore required restp rest keyp aok))
      (check-no-defaults optional)
      (check-no-defaults keys)
      (when auxp (error 'message-lambda-list-error :arg '&aux :lambda-list lambda-list)))))

(defun create-msg-lambda-list (lambda-list)
  "Create a message lambda list from a reply's lambda list"
  (loop for x in lambda-list
     collect (if (consp x) (car x) x)
     if (eq x '&key) do (loop-finish)))

;;;
;;; Message definition (finally!)
;;;

;; The defmessage macro basically expands to a call to this function (after processing
;; its args, checking lamda-list, etc.)
(defun ensure-message (name &rest all-keys &key lambda-list &allow-other-keys)
  (or (awhen-prog1 (find-message name nil)
        (set-arg-info it :lambda-list lambda-list))
      (setf (%find-message name)
            (apply 'make-message :name name :lambda-list lambda-list all-keys))))

;; This handles actual setup of the message object (and finalization)
(defun make-message (&key name lambda-list (documentation ""))
  (let ((message (%make-message :name name :lambda-list lambda-list)))
    (set-arg-info message :lambda-list lambda-list)
    (finalize-message message)
    (setf (documentation message 'message) documentation)
    message))

;; Finalizing a message sets the function definition of the message to a
;; lambda that calls the top-level dispatch function on the message args.
(defun finalize-message (message)
  (let ((name (message-name message)))
    (when (and (fboundp name) (not (find-message name nil)))
      (cerror "Replace definition." 'clobbering-function-definition :function name))
    (setf (fdefinition name) (lambda (&rest args) (apply-message message args)))))

;;; defmessage macro

;; This is the actual message definition macro.
;; It first verifies that the lambda-list provided is a valid message ll,
;; then expands to a call to ensure-message
;; This pair just pretties up the options during macro expansion
(defmacro defmessage (name lambda-list &rest options)
  `(progn
     (check-message-lambda-list ',lambda-list)
     (ensure-message ',name :lambda-list ',lambda-list
                     ,@(canonize-message-options options))))

(defun canonize-message-option (option)
  `(,(car option) ,(cadr option)))

(defun canonize-message-options (options)
  (mapcan 'canonize-message-option options))
