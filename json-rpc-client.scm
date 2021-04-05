;;;; json-rpc-client.scm
;
;; An implementation of the JSON-RPC protocol
;;
;; This file contains a client implementation.
;
; Copyright (c) 2013, Tim van der Linden
; All rights reserved.

; Redistribution and use in source and binary forms, with or without
; modification, are permitted provided that the following conditions are met:

; Redistributions of source code must retain the above copyright notice, this
; list of conditions and the following disclaimer. 
; Redistributions in binary form must reproduce the above copyright notice,
; this list of conditions and the following disclaimer in the documentation
; and/or other materials provided with the distribution. 
; Neither the name of the author nor the names of its contributors may be
; used to endorse or promote products derived from this software without
; specific prior written permission. 

; THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
; AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
; IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
; ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR CONTRIBUTORS BE
; LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR 
; CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
; SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
; INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
; CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
; ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
; POSSIBILITY OF SUCH DAMAGE.

(module json-rpc-client
  (json-rpc-server)

(import chicken scheme)
(use medea extras srfi-1 data-structures mailbox-threads)

; Setup the custom error handlers
(define (server-setup-arguments-error type expected given)
  (signal
   (make-property-condition
    'exn 'message
    (sprintf "Cannot setup connection, the ~S is invalid. Expected ~A type but got ~A."
	     type expected given))))

(define (server-setup-data-error type message)
  (signal
   (make-property-condition
    'exn 'message
    (sprintf "Cannot build JSON-RPC request, the given ~S data is invalid. The ~S ~A"
	     type type message))))

; As specified in the spec, when in error, the JSON-RPC server MUST return a code and a native message
; and MAY return additional data in structured form.
(define (json-rpc-server-error code message #!optional data)
  (signal
    (make-property-condition
     'exn 'message
     (sprintf "The JSON-RPC server returned an error. ~%Errorcode: ~A ~%Native message: ~A ~%Native data: ~A"
	      code message (if data
			       data
			       "No data returned.")))))

; Helper for checking which type we have, did not want to use another dependency for that :)
(define (get-type x)
  (cond ((input-port? x) "an input port")
	((output-port? x) "an output port")
	((number? x) "a number")
	((pair? x) "a pair")
	((string? x) "a string")
	((list? x) "a list")
	((vector? x) "a vector")
	((boolean? x) "a boolean")
	("something unknown")))

; Setup the server connection and return a procedure to setup the method and optional params
; Do some basic checking if the input, output and version are as expected
;; - input: input port of the JSON-RPC server
;; - output: output port of the JSON-RPC server
;; - version: the JSON-RPC version in which we want to communicate
;; - full-data: disclose full data or only the SPEC compliant "result" part of the response
;; - public-receiver: user defined procedure which will fire when receiving a broadcast message 
;; - test-mode: simple flag that gives the ability to not wait on thread-mailbox input when running a test cycle
;;
;; When successfully called, the lambda will return the CHICKEN data containing the server response
;; unless we send the request as a notification
(define (json-rpc-server input output #!key (version "2.0") (full-data #f) (public-receiver #f) (test-mode #f))
  (cond ((not (input-port? input)) (server-setup-arguments-error "input port" "input-port" (get-type input)))
	((not (output-port? output)) (server-setup-arguments-error "output port" "output-port" (get-type output)))
	((not (is-valid-version? version)) (server-setup-arguments-error "version" "2.0" version))
	(else
	 (thread-start! (listener-thread input (current-thread) public-receiver)) ; Start the looping listener thread
	 (lambda (method . params)
	   (cond ((not (is-valid-method? method)) (server-setup-data-error "method" "can only be a string or a symbol."))
		 ((not (are-valid-params? params)) (server-setup-data-error "params" "can only be a vector or an alist."))
		 (else
		  (send-request (remove null? (list (cons 'jsonrpc version)
						    (cons 'method (if (symbol? method)
								      (symbol->string method)
								      method))
						    (if (null? params)
							'()
							(cons 'params (build-params params)))
						    (if (symbol? method) ; Hack to make this request a notification or not
							'()
							(cons 'id "1")))) ; ID is hardcoded - can't handle more then one request at a time...or can we?
				output)
		  (when (and (not (symbol? method)) ; If it is not a symbol, then we expect a response 
			     (not test-mode)) ; If we are not in test-mode, then we expect a response
			(if full-data
			    (thread-receive) ; Return the full response data
			    (let ((data (thread-receive))) ; Else drill down and get the pretty parts
			      (cond ((alist-ref 'result data) (alist-ref 'result data)) ; Return only the "result" part of the response
				    ((alist-ref 'error data) ; If we get an error from the server, raise a json-rpc-server error type 
				     (json-rpc-server-error
				      (alist-ref 'code (alist-ref 'error data))
				      (alist-ref 'message (alist-ref 'error data))
				      (if (alist-ref 'data (alist-ref 'error data))
					  (alist-ref 'data (alist-ref 'error data))
					  #f)))))))))))))

; Helper for building a vector or alist from the parameters if present
(define (build-params params)
  (if (keyword? (car params)) 
      (build-alist params)
      (list->vector (build-vector params))))

; Helper for building an alist
(define (build-alist params)
  (if (null? params) 
      '()
      (cons (cons (car params) (car (cdr params))) (build-alist (cdr (cdr params))))))

; Helper for building a vector
(define (build-vector params)
  (if (null? params)
      '()
      (cons (symbol->string(car params)) (build-vector (cdr params)))))

; Check if the method is a string as defined in the spec...or a symbol, which is a small hack to set the request as a notification
(define (is-valid-method? method)
  (or (string? method)
      (symbol? method)))

; Check if the params are a list as defined in the spec
(define (are-valid-params? params)
  (list? params)) ; Assumptions? Don't know if this check is enough (check for null (is also a list) or list)

; Check if the version is correctly formatted as defined in the spec
(define (is-valid-version? version)
  (string=? version "2.0"))

; Send the actual request using Medea
(define (send-request request output)
  (write-json request output))

; Create the looping listener thread which will dispatch messages
;; Keep reading the JSON sent back from the server. If the response contains an ID then this is a 
;; response to the request sent, so dispatch a message to the current threads mailbox. 
;; Otherwise, when defined, fire the user defined public receiver procedure with the public data sent by the server. 
(define (listener-thread input current-thread public-receiver) 
  (make-thread
   (lambda ()
     (let listen-loop
       ; Note that we have to set Medea to not consume trailing whitespace for otherwise Medea will swallow
       ; the first character of the *next* JSON string waiting in the port and thus render that string useless.
       ((data (read-json input consume-trailing-whitespace: #f)))
       (if (alist-ref 'id data)
	   (thread-send current-thread data)
	   (when public-receiver ; If we have a public-receiver procedure (not #f), call it with data
		 (public-receiver data)))
       (listen-loop (read-json input consume-trailing-whitespace: #f))))
   'listener))

)
