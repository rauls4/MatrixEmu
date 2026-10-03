; demo.asm — program for the MatrixEmu bytecode VM.
; Runs from an ESP32-S3 image segment loaded at 0x3FC00000.
; Talks to the 64x32 panel only through PIX/FILL/CLR. The HUB75
; scan (row pair, latch, blanking) is the emulator's job.
;
; About 1.9 s of a 3-pixel-wide color bar sweeping left to right,
; then a 2x2 white dot bouncing inside the panel, forever.

        clr
        ldi r0, 0

sweep:
        clr
        ldi r6, 21
        blt r0, r6, sred
        ldi r6, 42
        blt r0, r6, sgrn
        ldi r3, 40
        ldi r4, 70
        ldi r5, 255
        jmp sdraw
sred:
        ldi r3, 255
        ldi r4, 48
        ldi r5, 0
        jmp sdraw
sgrn:
        ldi r3, 0
        ldi r4, 255
        ldi r5, 64
sdraw:
        ldi r1, 0
        ldi r2, 3
        ldi r6, 32
        fillr r0, r1, r2, r6, r3, r4, r5
        delay 30
        millis r7
        add r0, r0, 1
        ldi r6, 62
        blt r0, r6, sweep

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
        millis r7
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
