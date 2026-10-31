BEEBASM = beebasm
SRC = galaxa.asm
OUT = galaxa.ssd

JSBEEB_DIR = $(HOME)/.local/share/jsbeeb
JSBEEB_URL = http://localhost:5173/\?disc1=$(OUT)\&autoboot

.PHONY: all clean run test

all: $(OUT)

$(OUT): $(SRC) title.asm !BOOT
	$(BEEBASM) -i $(SRC) -do $(OUT) -opt 3 -v -d -title GALAXA -labels galaxa.sym > galaxa.lst

run: $(OUT)
	@ln -sf $(CURDIR)/$(OUT) $(JSBEEB_DIR)/public/discs/$(OUT)
	@if ! lsof -i :5173 -sTCP:LISTEN >/dev/null 2>&1; then \
		cd $(JSBEEB_DIR) && npm start & \
		sleep 3; \
	fi
	@open $(JSBEEB_URL)

title.asm: tools/title.mjs $(SRC)
	node tools/title.mjs

# Headless smoothness test: 8000 frames (160 seconds of play, into wave 3: the boss makes waves longer) in jsbeeb
test: $(OUT)
	JSBEEB_DIR=$(JSBEEB_DIR) node tools/smoothness.mjs 8000

clean:
	rm -f $(OUT) galaxa.lst galaxa.sym title.asm
