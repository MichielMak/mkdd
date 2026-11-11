/*
 * mkdd-pads: list connected controllers the way Dolphin's SDL backend names them.
 *
 *   mkdd-pads [HINT=VALUE]...              one line per controller: "<id>\t<gamepad>\t<name>"
 *   mkdd-pads --watch PID [HINT=VALUE]...  the same with a leading "=" for the controllers
 *                                          there now and a line "." after them, then "+"
 *                                          or "-" lines as controllers come and go, until
 *                                          process PID exits
 *
 * <id> is the number Dolphin puts in "SDL/<id>/<name>" and <gamepad> is 1 when
 * SDL knows the controller's layout. HINT=VALUE are extra SDL hints, e.g. from
 * Dolphin.ini [SDL_Hints]. The launcher writes Dolphin mappings from this.
 *
 * Built against the AppImage's own libSDL3.so.0 and run through sharun, so the
 * names match what Dolphin sees. SDL's headers are not needed: the few functions
 * used are declared below.
 */
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>

typedef uint32_t SDL_JoystickID;
typedef struct SDL_Gamepad SDL_Gamepad;
typedef struct SDL_Joystick SDL_Joystick;
/* SDL_Event is a 128-byte union. Device events (SDL_JoyDeviceEvent) hold
 * type, reserved, timestamp, then the instance id. */
typedef union {
	struct {
		uint32_t type;
		uint32_t reserved;
		uint64_t timestamp;
		SDL_JoystickID which;
	} jdevice;
	uint8_t padding[128];
} SDL_Event;

bool SDL_SetHint(const char *name, const char *value);
bool SDL_Init(uint32_t flags);
void SDL_Quit(void);
void SDL_PumpEvents(void);
void SDL_Delay(uint32_t ms);
void SDL_free(void *mem);
void SDL_SetEventEnabled(uint32_t type, bool enabled);
bool SDL_WaitEventTimeout(SDL_Event *event, int32_t timeout_ms);
SDL_JoystickID *SDL_GetJoysticks(int *count);
SDL_Gamepad *SDL_OpenGamepad(SDL_JoystickID id);
SDL_Joystick *SDL_OpenJoystick(SDL_JoystickID id);
const char *SDL_GetGamepadName(SDL_Gamepad *gamepad);
const char *SDL_GetJoystickName(SDL_Joystick *joystick);
int SDL_GetNumJoystickButtons(SDL_Joystick *joystick);
int SDL_GetNumJoystickAxes(SDL_Joystick *joystick);
int SDL_GetNumJoystickHats(SDL_Joystick *joystick);

#define SDL_INIT_JOYSTICK 0x00000200u
#define SDL_INIT_HAPTIC 0x00001000u
#define SDL_INIT_GAMEPAD 0x00002000u
#define SDL_EVENT_JOYSTICK_FIRST 0x600u
#define SDL_EVENT_JOYSTICK_ADDED 0x605u
#define SDL_EVENT_JOYSTICK_REMOVED 0x606u
#define SDL_EVENT_GAMEPAD_LAST 0x6ffu

#define MAX_PADS 64

/* The controllers Dolphin would have, with the id it gives each. */
static struct {
	SDL_JoystickID instance;
	int id;
	int gamepad;
	char name[256];
	bool present;
} pads[MAX_PADS];

static void print(char tag, int i)
{
	if (tag)
		printf("%c\t", tag);
	printf("%d\t%d\t%s\n", pads[i].id, pads[i].gamepad, pads[i].name);
	fflush(stdout);
}

/* Open a controller as Dolphin does (InputBackend::OpenAndAddDevice) and give it
 * the lowest id not used by a present controller of the same name
 * (ControllerInterface::AddDevice). Returns its slot, or -1. */
static int add(SDL_JoystickID instance)
{
	for (int i = 0; i < MAX_PADS; i++)
		if (pads[i].present && pads[i].instance == instance)
			return -1;
	SDL_Gamepad *gc = SDL_OpenGamepad(instance);
	SDL_Joystick *js = SDL_OpenJoystick(instance);
	if (js == NULL)
		return -1;
	if (SDL_GetNumJoystickButtons(js) > 255 || SDL_GetNumJoystickAxes(js) > 255 ||
	    SDL_GetNumJoystickHats(js) > 255)
		return -1;
	const char *name = gc != NULL ? SDL_GetGamepadName(gc) : SDL_GetJoystickName(js);
	if (name == NULL)
		name = "Unknown";

	int slot = -1;
	for (int i = 0; i < MAX_PADS && slot < 0; i++)
		if (!pads[i].present)
			slot = i;
	if (slot < 0)
		return -1;
	int id = 0;
	for (bool used = true; used; ) {
		used = false;
		for (int i = 0; i < MAX_PADS; i++)
			if (pads[i].present && pads[i].id == id && strcmp(pads[i].name, name) == 0) {
				used = true;
				id++;
				break;
			}
	}
	pads[slot].instance = instance;
	pads[slot].id = id;
	pads[slot].gamepad = gc != NULL;
	snprintf(pads[slot].name, sizeof pads[slot].name, "%s", name);
	pads[slot].present = true;
	return slot;
}

int main(int argc, char **argv)
{
	pid_t watch = 0;
	int first_hint = 1;
	if (argc >= 3 && strcmp(argv[1], "--watch") == 0) {
		watch = (pid_t)atol(argv[2]);
		first_hint = 3;
	}

	/* Dolphin 2609a's defaults (InputCommon/ControllerInterface/SDL/SDL.cpp).
	 * Some of them change controller names, e.g. combined Joy-Cons. */
	SDL_SetHint("SDL_JOYSTICK_ENHANCED_REPORTS", "1");
	SDL_SetHint("SDL_JOYSTICK_HIDAPI_PS5_PLAYER_LED", "0");
	SDL_SetHint("SDL_JOYSTICK_HIDAPI_COMBINE_JOY_CONS", "1");
	SDL_SetHint("SDL_JOYSTICK_HIDAPI_VERTICAL_JOY_CONS", "0");
	SDL_SetHint("SDL_JOYSTICK_HIDAPI_GAMECUBE", "1");
	for (int i = first_hint; i < argc; i++) {
		char *eq = strchr(argv[i], '=');
		if (eq == NULL)
			continue;
		*eq = '\0';
		SDL_SetHint(argv[i], eq + 1);
	}

	if (!SDL_Init(SDL_INIT_JOYSTICK | SDL_INIT_HAPTIC | SDL_INIT_GAMEPAD))
		return 1;
	/* Only hotplug events matter; skip button and stick events. */
	for (uint32_t t = SDL_EVENT_JOYSTICK_FIRST; t <= SDL_EVENT_GAMEPAD_LAST; t++)
		if (t != SDL_EVENT_JOYSTICK_ADDED && t != SDL_EVENT_JOYSTICK_REMOVED)
			SDL_SetEventEnabled(t, false);
	/* HIDAPI controllers can show up a moment after init. */
	for (int i = 0; i < 5; i++) {
		SDL_PumpEvents();
		SDL_Delay(40);
	}

	int count = 0;
	SDL_JoystickID *ids = SDL_GetJoysticks(&count);
	for (int i = 0; ids != NULL && i < count; i++) {
		int slot = add(ids[i]);
		if (slot >= 0)
			print(watch ? '=' : 0, slot);
	}
	SDL_free(ids);
	if (watch > 0) {
		printf(".\n");
		fflush(stdout);
	}

	/* Watch until the given process is gone. The initial add events were
	 * handled above, so add() skips them. */
	while (watch > 0 && kill(watch, 0) == 0) {
		SDL_Event e;
		if (!SDL_WaitEventTimeout(&e, 500))
			continue;
		if (e.jdevice.type == SDL_EVENT_JOYSTICK_ADDED) {
			int slot = add(e.jdevice.which);
			if (slot >= 0)
				print('+', slot);
		} else if (e.jdevice.type == SDL_EVENT_JOYSTICK_REMOVED) {
			for (int i = 0; i < MAX_PADS; i++)
				if (pads[i].present && pads[i].instance == e.jdevice.which) {
					pads[i].present = false;
					print('-', i);
				}
		}
	}
	SDL_Quit();
	return 0;
}
