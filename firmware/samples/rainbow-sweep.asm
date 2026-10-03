; rainbow-sweep.asm — 4px bar walks left to right through seven colors.
start:
        ldi r0, 0
sweep:
        clr
        ldi r6, 8
        blt r0, r6, c_red
        ldi r6, 16
        blt r0, r6, c_org
        ldi r6, 24
        blt r0, r6, c_yel
        ldi r6, 32
        blt r0, r6, c_grn
        ldi r6, 40
        blt r0, r6, c_cyn
        ldi r6, 48
        blt r0, r6, c_blu
        ldi r3, 180
        ldi r4, 40
        ldi r5, 255
        jmp draw
c_red:
        ldi r3, 255
        ldi r4, 30
        ldi r5, 30
        jmp draw
c_org:
        ldi r3, 255
        ldi r4, 140
        ldi r5, 20
        jmp draw
c_yel:
        ldi r3, 255
        ldi r4, 220
        ldi r5, 40
        jmp draw
c_grn:
        ldi r3, 40
        ldi r4, 220
        ldi r5, 60
        jmp draw
c_cyn:
        ldi r3, 40
        ldi r4, 220
        ldi r5, 220
        jmp draw
c_blu:
        ldi r3, 50
        ldi r4, 100
        ldi r5, 255
draw:
        ldi r1, 0
        ldi r2, 4
        ldi r6, 32
        fillr r0, r1, r2, r6, r3, r4, r5
        delay 40
        add r0, r0, 4
        ldi r6, 64
        blt r0, r6, sweep
        jmp start
