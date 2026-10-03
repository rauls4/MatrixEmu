; bouncing-dot.asm — 2x2 white dot inside 64x32.
start:
        ldi r0, 0
        ldi r1, 0
        ldi r2, 0
        ldi r3, 0
bounce:
        clr
        ldi r4, 2
        ldi r5, 2
        ldi r6, 255
        fillr r0, r1, r4, r5, r6, r6, r6
        delay 40
        ldi r6, 0
        beq r2, r6, x_right
        add r0, r0, -1
        ldi r6, 0
        beq r0, r6, x_flip_right
        jmp y_move
x_right:
        add r0, r0, 1
        ldi r6, 63
        bge r0, r6, x_flip_left
        jmp y_move
x_flip_left:
        ldi r0, 62
        ldi r2, 1
        jmp y_move
x_flip_right:
        ldi r2, 0
y_move:
        ldi r6, 0
        beq r3, r6, y_down
        add r1, r1, -1
        ldi r6, 0
        beq r1, r6, y_flip_down
        jmp bounce
y_down:
        add r1, r1, 1
        ldi r6, 31
        bge r1, r6, y_flip_up
        jmp bounce
y_flip_up:
        ldi r1, 30
        ldi r3, 1
        jmp bounce
y_flip_down:
        ldi r3, 0
        jmp bounce
