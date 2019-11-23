format ELF64 executable

;; The code in this macro is placed at the end of each Forth word. When we are
;; executing a definition, this code is what causes execution to resume at the
;; next word in that definition.
macro next {
  ;; RSI points to the address of the definition of the next word to execute.
  lodsq                   ; Load value at RSI into RAX and increment RSI
  ;; Now RAX contains the location of the next word to execute. The first 8
  ;; bytes of this word is the address of the codeword, which is what we want
  ;; to execute.
  jmp qword [rax]         ; Jump to the codeword of the current word
}

;; pushr and popr work on the return stack, whose location is stored in the
;; register RBP.
macro pushr x {
  sub rbp, 8
  mov qword [rbp], x
}
macro popr x {
  mov x, [rbp]
  add rbp, 8
}

segment readable executable

main:
  cld                        ; Clear direction flag so LODSQ does the right thing.
  mov rbp, return_stack_top  ; Initialize return stack

  mov rsi, program
  next

program: dq MAIN

;; The codeword is the code that will be executed at the beginning of a forth
;; word. It needs to save the old RSI and update it to point to the next word to
;; execute.
docol:
  pushr rsi            ; Save old value of RSI on return stack; we will continue execution there after we are done executing this word
  lea rsi, [rax + 8]   ; RAX currently points to the address of the codeword, so we want to continue at RAX+8
  next                 ; Execute word pointed to by RSI

;; This word is called at the end of a Forth definition. It just needs to
;; restore the old value of RSI (saved by 'docol') and resume execution.
EXIT:
  dq .start
.start:
  popr rsi
  next

;; LIT is a special word that reads the next "word pointer" and causes it to be
;; placed on the stack rather than executed.
LIT:
  dq .start
.start:
  lodsq
  push rax
  next

;; BRANCH is the fundamental mechanism for branching. BRANCH reads the next word
;; as a signed integer literal and jumps by that offset.
BRANCH:
  dq .start
.start:
  add rsi, [rsi] ; [RSI], which is the next word, contains the offset; we add this to the instruction pointer.
  next           ; Then, we can just continue execution as normal

;; 0BRANCH is like BRANCH, but it jumps only if the top of the stack is zero.
ZBRANCH:
  dq .start
.start:
  ;; Compare top of stack to see if we should branch
  pop rax
  cmp rax, 0
  jnz .dont_branch
.do_branch:
  jmp BRANCH.start
.dont_branch:
  add rsi, 8     ; We need to skip over the next word, which contains the offset.
  next

;; Expects a character on the stack and prints it to standard output.
EMIT:
  dq .start
.start:
  pushr rsi
  pushr rax
  mov rax, 1
  mov rdi, 1
  lea rsi, [rsp]
  mov rdx, 1
  syscall
  add rsp, 8
  popr rax
  popr rsi
  next

;; Prints a newline to standard output.
NEWLINE:
  dq docol
  dq LIT, $A
  dq EMIT
  dq EXIT

;; Read a word from standard input and push it onto the stack as a pointer and a
;; size. The pointer is valid until the next call to READ_WORD.
READ_WORD:  ; 400170
  dq .start
.start:
  mov [.rsi], rsi
  mov [.rax], rax

.skip_whitespace:
  ;; Read characters into .char_buffer until one of them is not whitespace.
  mov rax, 0
  mov rdi, 0
  mov rsi, .char_buffer
  mov rdx, 1
  syscall

  cmp [.char_buffer], ' '
  je .skip_whitespace
  cmp [.char_buffer], $A
  je .skip_whitespace

.alpha:
  ;; We got a character that wasn't whitespace. Now read the actual word.
  mov [.length], 0

.read_alpha:
  mov al, [.char_buffer]
  movzx rbx, [.length]
  mov rsi, .buffer
  add rsi, rbx
  mov [rsi], al
  inc [.length]

  mov rax, 0
  mov rdi, 0
  mov rsi, .char_buffer
  mov rdx, 1
  syscall

  cmp [.char_buffer], ' '
  je .end
  cmp [.char_buffer], $A
  jne .read_alpha

.end:
  push .buffer
  movzx rax, [.length]
  push rax

  mov rsi, [.rsi]
  mov rax, [.rax]

  next

;; Takes a string (in the form of a pointer and a length on the stack) and
;; prints it to standard output.
TELL:
  dq .start
.start:
  mov rbx, rsi
  mov rcx, rax

  mov rax, 1
  mov rdi, 1
  pop rdx     ; Length
  pop rsi     ; Buffer
  syscall

  mov rax, rcx
  mov rsi, rbx
  next

;; Exit the program cleanly.
TERMINATE:
  dq .start
.start:
  mov rax, $3C
  mov rdi, 0
  syscall

PUSH_HELLO_CHARS:
  dq docol
  dq LIT, $A
  dq LIT, 'o'
  dq LIT, 'l'
  dq LIT, 'l'
  dq LIT, 'e'
  dq LIT, 'H'
  dq EXIT

PUSH_YOU_TYPED:
  dq .start
.start:
  push you_typed_string
  push you_typed_string.length
  next

HELLO:
  dq docol
  dq LIT, 'H', EMIT
  dq LIT, 'e', EMIT
  dq LIT, 'l', EMIT
  dq LIT, 'l', EMIT
  dq LIT, 'o', EMIT
  dq LIT, '!', EMIT
  dq NEWLINE
  dq EXIT

;; .U prints the value on the stack as an unsigned integer in hexadecimal.
DOTU:
  dq .start
.start:
  mov [.length], 0
  pop rax                       ; RAX = value to print
  push rsi                      ; Save value of RSI

  ;; We start by constructing the buffer to print in reverse

.loop:
  mov rdx, 0
  mov rbx, $10
  div rbx                       ; Put remainer in RDX and quotient in RAX

  ;; Place the appropriate character in the buffer
  mov rsi, .chars
  add rsi, rdx
  mov bl, [rsi]
  mov rdi, .rbuffer
  add rdi, [.length]
  mov [rdi], bl
  inc [.length]

  ;; .printed_length is the number of characters that we ulitmately want to
  ;; print. If we have printed a non-zero character, then we should update
  ;; .printed_length.
  cmp bl, '0'
  je .skip_updating_real_length
  mov rbx, [.length]
  mov [.printed_length], rbx
.skip_updating_real_length:

  cmp [.length], 16
  jle .loop

  ;; Flip buffer around, since it is currently reversed
  mov rcx, [.printed_length]
.flip:
  mov rsi, .rbuffer
  add rsi, rcx
  dec rsi
  mov al, [rsi]

  mov rdi, .buffer
  add rdi, [.printed_length]
  sub rdi, rcx
  mov [rdi], al

  loop .flip

  ;; Print the buffer
  mov rax, 1
  mov rdi, 1
  mov rsi, .buffer
  mov rdx, [.printed_length]
  syscall

  ;; Restore RSI and continue execution
  pop rsi
  next

MAIN:
  dq docol
  dq HELLO
  dq LIT, 1234567890, DOTU, NEWLINE
  dq LIT, $ABCD, DOTU, NEWLINE
  dq LIT, $1234ABCD5678EFAB, DOTU, NEWLINE
  dq TERMINATE

segment readable writable

you_typed_string db 'You typed: '
.length = $ - you_typed_string

READ_WORD.rsi dq ?
READ_WORD.rax dq ?
READ_WORD.max_size = $FF
READ_WORD.buffer rb READ_WORD.max_size
READ_WORD.length db ?
READ_WORD.char_buffer db ?

DOTU.chars db '0123456789ABCDEF'
DOTU.buffer rq 16               ; 64-bit number has no more than 16 digits in hex
DOTU.rbuffer rq 16
DOTU.length dq ?
DOTU.printed_length dq ?

;; Return stack
rq $2000
return_stack_top:
