;;; rust-mode.el --- A major emacs mode for editing Rust source code

;; Version: 0.2.0
;; Author: Mozilla
;; Url: https://github.com/mozilla/rust

(eval-when-compile (require 'cl))
(eval-when-compile (require 'misc))

;; Syntax definitions and helpers
(defvar rust-mode-syntax-table
  (let ((table (make-syntax-table)))

    ;; Operators
    (loop for i in '(?+ ?- ?* ?/ ?& ?| ?^ ?! ?< ?> ?~ ?@)
          do (modify-syntax-entry i "." table))

    ;; Strings
    (modify-syntax-entry ?\" "\"" table)
    (modify-syntax-entry ?\\ "\\" table)

    ;; _ is a word-char
    (modify-syntax-entry ?_ "w" table)

    ;; Comments
    (modify-syntax-entry ?/  ". 124b" table)
    (modify-syntax-entry ?*  ". 23"   table)
    (modify-syntax-entry ?\n "> b"    table)
    (modify-syntax-entry ?\^m "> b"   table)

    table))

(defcustom rust-indent-offset 4
  "*Indent Rust code by this number of spaces.")

(defun rust-paren-level () (nth 0 (syntax-ppss)))
(defun rust-in-str-or-cmnt () (nth 8 (syntax-ppss)))
(defun rust-rewind-past-str-cmnt () (goto-char (nth 8 (syntax-ppss))))
(defun rust-rewind-irrelevant ()
  (let ((starting (point)))
    (skip-chars-backward "[:space:]\n")
    (if (looking-back "\\*/") (backward-char))
    (if (rust-in-str-or-cmnt)
        (rust-rewind-past-str-cmnt))
    (if (/= starting (point))
        (rust-rewind-irrelevant))))

(defun rust-mode-indent-line ()
  (interactive)
  (let ((indent
         (save-excursion
           (back-to-indentation)
           (let ((level (rust-paren-level)))
             (cond
              ;; A function return type is 1 level indented
              ((looking-at "->") (* rust-indent-offset (+ level 1)))

              ;; A closing brace is 1 level unindended
              ((looking-at "}") (* rust-indent-offset (- level 1)))

              ; Doc comments in /** style with leading * indent to line up the *s
              ((and (nth 4 (syntax-ppss)) (looking-at "*"))
               (+ 1 (* rust-indent-offset level)))

              ;; If we're in any other token-tree / sexp, then:
              ;;  - [ or ( means line up with the opening token
              ;;  - { means indent to either nesting-level * rust-indent-offset,
              ;;    or one further indent from that if either current line
              ;;    begins with 'else', or previous line didn't end in
              ;;    semi, comma or brace (other than whitespace and line
              ;;    comments) , and wasn't an attribute.  But if we have 
              ;;    something after the open brace and ending with a comma,
              ;;    treat it as fields and align them.  PHEW.
              ((> level 0)
               (let ((pt (point)))
                 (rust-rewind-irrelevant)
                 (backward-up-list)
                 (cond 
                  ((and
                      (looking-at "[[(]")
                      ; We don't want to indent out to the open bracket if the
                      ; open bracket ends the line
                      (save-excursion 
                        (forward-char)
                        (not (looking-at "[[:space:]]*\\(?://.*\\)?$"))))
                   (+ 1 (current-column)))
                  ;; Check for fields on the same line as the open curly brace:
                  ((looking-at "{[[:blank:]]*[^}\n]*,[[:space:]]*$")
                   (progn
                    (forward-char)
                    (forward-to-word 1)
                    (current-column)))
                  (t (progn
                     (goto-char pt)
                     (back-to-indentation)
                     (if (looking-at "\\<else\\>")
                         (* rust-indent-offset (+ 1 level))
                       (progn
                         (goto-char pt)
                         (beginning-of-line)
                         (rust-rewind-irrelevant)
                         (end-of-line)
                         (if (looking-back "[,;{}(][[:space:]]*\\(?://.*\\)?")
                             (* rust-indent-offset level)
                           (back-to-indentation)
                           (if (looking-at "#")
                               (* rust-indent-offset level)
                             (* rust-indent-offset (+ 1 level)))))))))))

              ;; Otherwise we're in a column-zero definition
              (t 0))))))
    (cond
     ;; If we're to the left of the indentation, reindent and jump to it.
     ((<= (current-column) indent)
      (indent-line-to indent))

     ;; We're to the right; if it needs indent, do so but save excursion.
     ((not (eq (current-indentation) indent))
      (save-excursion (indent-line-to indent))))))


;; Font-locking definitions and helpers
(defconst rust-mode-keywords
  '("as"
    "break"
    "do"
    "else" "enum" "extern"
    "false" "fn" "for"
    "if" "impl" "in"
    "let" "loop"
    "match" "mod" "mut"
    "priv" "pub"
    "ref" "return"
    "self" "static" "struct" "super"
    "true" "trait" "type"
    "unsafe" "use"
    "while"))

(defconst rust-special-types
  '("u8" "i8"
    "u16" "i16"
    "u32" "i32"
    "u64" "i64"

    "f32" "f64"
    "float" "int" "uint"
    "bool"
    "str" "char"))

(defconst rust-re-ident "[[:word:][:multibyte:]_][[:word:][:multibyte:]_[:digit:]]*")
(defconst rust-re-CamelCase "[[:upper:]][[:word:][:multibyte:]_[:digit:]]*")
(defun rust-re-word (inner) (concat "\\<" inner "\\>"))
(defun rust-re-grab (inner) (concat "\\(" inner "\\)"))
(defun rust-re-grabword (inner) (rust-re-grab (rust-re-word inner)))
(defun rust-re-item-def (itype)
  (concat (rust-re-word itype) "[[:space:]]+" (rust-re-grab rust-re-ident)))

(defvar rust-mode-font-lock-keywords
  (append
   `(
     ;; Keywords proper
     (,(regexp-opt rust-mode-keywords 'words) . font-lock-keyword-face)

     ;; Special types
     (,(regexp-opt rust-special-types 'words) . font-lock-type-face)

     ;; Attributes like `#[bar(baz)]`
     (,(rust-re-grab (concat "#\\[" rust-re-ident "[^]]*\\]"))
      1 font-lock-preprocessor-face)

     ;; Syntax extension invocations like `foo!`, highlight including the !
     (,(concat (rust-re-grab (concat rust-re-ident "!")) "[({[:space:]]")
      1 font-lock-preprocessor-face)

     ;; Field names like `foo:`, highlight excluding the :
     (,(concat (rust-re-grab rust-re-ident) ":[^:]") 1 font-lock-variable-name-face)

     ;; Module names like `foo::`, highlight including the ::
     (,(rust-re-grab (concat rust-re-ident "::")) 1 font-lock-type-face)

     ;; Lifetimes like `'foo`
     (,(concat "'" (rust-re-grab rust-re-ident) "[^']") 1 font-lock-variable-name-face)

     ;; Character constants, since they're not treated as strings
     ;; in order to have sufficient leeway to parse 'lifetime above.
     (,(rust-re-grab "'[^']'") 1 font-lock-string-face)
     (,(rust-re-grab "'\\\\[nrt]'") 1 font-lock-string-face)
     (,(rust-re-grab "'\\\\x[[:xdigit:]]\\{2\\}'") 1 font-lock-string-face)
     (,(rust-re-grab "'\\\\u[[:xdigit:]]\\{4\\}'") 1 font-lock-string-face)
     (,(rust-re-grab "'\\\\U[[:xdigit:]]\\{8\\}'") 1 font-lock-string-face)

     ;; CamelCase Means Type Or Constructor
     (,(rust-re-grabword rust-re-CamelCase) 1 font-lock-type-face)
     )

   ;; Item definitions
   (loop for (item . face) in

         '(("enum" . font-lock-type-face)
           ("struct" . font-lock-type-face)
           ("type" . font-lock-type-face)
           ("mod" . font-lock-type-face)
           ("use" . font-lock-type-face)
           ("fn" . font-lock-function-name-face)
           ("static" . font-lock-constant-face))

         collect `(,(rust-re-item-def item) 1 ,face))))


;; For compatibility with Emacs < 24, derive conditionally
(defalias 'rust-parent-mode
  (if (fboundp 'prog-mode) 'prog-mode 'fundamental-mode))


;;;###autoload
(define-derived-mode rust-mode rust-parent-mode "Rust"
  "Major mode for Rust code."

  ;; Basic syntax
  (set-syntax-table rust-mode-syntax-table)

  ;; Indentation
  (set (make-local-variable 'indent-line-function)
       'rust-mode-indent-line)

  ;; Fonts
  (set (make-local-variable 'font-lock-defaults)
       '(rust-mode-font-lock-keywords nil nil nil nil))

  ;; Misc
  (set (make-local-variable 'comment-start) "// ")
  (set (make-local-variable 'comment-end)   "")
  (set (make-local-variable 'indent-tabs-mode) nil))


;;;###autoload
(add-to-list 'auto-mode-alist '("\\.rs$" . rust-mode))

(defun rust-mode-reload ()
  (interactive)
  (unload-feature 'rust-mode)
  (require 'rust-mode)
  (rust-mode))

(provide 'rust-mode)

;; Issue #6887: Rather than inheriting the 'gnu compilation error
;; regexp (which is broken on a few edge cases), add our own 'rust
;; compilation error regexp and use it instead.
(defvar rustc-compilation-regexps
  (let ((file "\\([^\n]+\\)")
        (start-line "\\([0-9]+\\)")
        (start-col  "\\([0-9]+\\)")
        (end-line   "\\([0-9]+\\)")
        (end-col    "\\([0-9]+\\)")
        (error-or-warning "\\(?:[Ee]rror\\|\\([Ww]arning\\)\\)"))
    (let ((re (concat "^" file ":" start-line ":" start-col
                      ": " end-line ":" end-col
                      " \\(?:[Ee]rror\\|\\([Ww]arning\\)\\):")))
      (cons re '(1 (2 . 4) (3 . 5) (6)))))
  "Specifications for matching errors in rustc invocations.
See `compilation-error-regexp-alist for help on their format.")

(eval-after-load 'compile
  '(progn
     (add-to-list 'compilation-error-regexp-alist-alist
                  (cons 'rustc rustc-compilation-regexps))
     (add-to-list 'compilation-error-regexp-alist 'rustc)))

;;; rust-mode.el ends here
