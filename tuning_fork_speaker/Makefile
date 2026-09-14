CFLAGS ?= -fPIC -O2
LDFLAGS ?=

UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
	LDFLAGS += -dynamiclib -undefined dynamic_lookup
	LDFLAGS += -framework CoreFoundation -framework CoreAudio -framework AudioToolbox
else
	LDFLAGS += -shared -lpthread -lm -ldl
endif

ERTS_INCLUDE_DIR ?= $(shell erl -noshell -eval 'io:format("~s/include", [code:root_dir() ++ "/erts-" ++ erlang:system_info(version)])' -s init stop)

PRIV_DIR = priv
NIF_SO = $(PRIV_DIR)/tuning_fork_nif.so
NIF_SRC = c_src/tuning_fork_nif.c

all: $(NIF_SO)

$(PRIV_DIR):
	mkdir -p $(PRIV_DIR)

$(NIF_SO): $(NIF_SRC) c_src/miniaudio.h | $(PRIV_DIR)
	$(CC) $(CFLAGS) -I$(ERTS_INCLUDE_DIR) -Ic_src -o $@ $(NIF_SRC) $(LDFLAGS)

clean:
	rm -f $(NIF_SO)

.PHONY: all clean
