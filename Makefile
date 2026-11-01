BEEBASM = beebasm
SRC = galaxa.asm
OUT = galaxa.ssd

JSBEEB_DIR = $(HOME)/.local/share/jsbeeb
JSBEEB_URL = http://localhost:5173/\?disc1=$(OUT)\&autoboot

.PHONY: all clean run run-debug test

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

# P cycles the power level: single shot, double, rapid fire
galaxa-debug.ssd: $(SRC) title.asm !BOOT
	$(BEEBASM) -i $(SRC) -D DEBUG=1 -do $@ -opt 3 -v -d -title GALAXA -labels galaxa-debug.sym > galaxa-debug.lst

run-debug: galaxa-debug.ssd
	@ln -sf $(CURDIR)/galaxa-debug.ssd $(JSBEEB_DIR)/public/discs/galaxa-debug.ssd
	@if ! lsof -i :5173 -sTCP:LISTEN >/dev/null 2>&1; then \
		cd $(JSBEEB_DIR) && npm start & \
		sleep 3; \
	fi
	@open http://localhost:5173/\?disc1=galaxa-debug.ssd\&autoboot

title.asm: tools/title.mjs $(SRC)
	node tools/title.mjs

# Headless smoothness test: 8000 frames (160 seconds of play, into wave 3: the boss makes waves longer) in jsbeeb
test: $(OUT)
	JSBEEB_DIR=$(JSBEEB_DIR) node tools/smoothness.mjs 8000
	JSBEEB_DIR=$(JSBEEB_DIR) node tools/capsule.mjs

clean:
	rm -f $(OUT) galaxa.lst galaxa.sym title.asm galaxa-debug.ssd galaxa-debug.lst galaxa-debug.sym
