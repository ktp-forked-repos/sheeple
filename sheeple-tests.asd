(asdf:defsystem sheeple-tests
  :version "Baahh"
  :description "Clone-crazy hackery tool, unit tests."
  :maintainer "Kat <zkat@Dagon>"
  :author "Kat <zkat@Dagon>"
  :licence "MIT"
  :depends-on (:sheeple :fiveam)
  :serial t
  :components 
  ((:module tests
	    :serial t
	    :components
	    ((:file "packages")
	     (:file "sheeple")
	     (:file "buzzwords")))))