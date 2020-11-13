.PHONY: install clean
SHELL = bash

MAKEFLAGS += --warn-undefined-variables --no-builtin-rules
.DELETE_ON_ERROR:

HS_SRC := $(shell find src -type f) kempe.cabal

factorial.S: examples/factorial.kmp
	kc $^ --dump-asm > $@

factorial.o: factorial.S
	nasm $^ -f elf64 -o $@

rts.o: rts.S
	nasm $^ -f elf64 -o $@

install:
	cabal install exe:kc --overwrite-policy=always

moddeps.svg: $(HS_SRC)
	graphmod src | dot -Tsvg -o$@

clean:
	rm -rf dist-newstyle *.rlib *.d *.rmeta *.o stack.yaml.lock moddeps.svg factorial.S
