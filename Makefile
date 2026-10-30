BEEBASM = beebasm
SRC = swarm.asm
OUT = swarm.ssd

JSBEEB_DIR = $(HOME)/.local/share/jsbeeb
JSBEEB_URL = http://localhost:5173/\?disc1=$(OUT)\&autoboot

.PHONY: all clean run test

all: $(OUT)

$(OUT): $(SRC) !BOOT
	$(BEEBASM) -i $(SRC) -do $(OUT) -opt 3 -v -d -labels swarm.sym > swarm.lst

run: $(OUT)
	@ln -sf $(CURDIR)/$(OUT) $(JSBEEB_DIR)/public/discs/$(OUT)
	@if ! lsof -i :5173 -sTCP:LISTEN >/dev/null 2>&1; then \
		cd $(JSBEEB_DIR) && npm start & \
		sleep 3; \
	fi
	@open $(JSBEEB_URL)

# Headless smoothness test: 3000 frames (1 minute of play) in jsbeeb
test: $(OUT)
	JSBEEB_DIR=$(JSBEEB_DIR) node tools/smoothness.mjs 3000

clean:
	rm -f $(OUT) swarm.lst swarm.sym
