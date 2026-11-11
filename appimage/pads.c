/*
 * mkdd-pads: list connected controllers the way Dolphin's SDL backend names them.
 *
 * Prints one line per SDL joystick: "<id>\t<gamepad>\t<name>", where <id> is the
 * number Dolphin puts in "SDL/<id>/<name>" and <gamepad> is 1 when SDL knows the
 * controller's layout. The launcher writes Dolphin mappings from this.
 *
 * Built against the AppImage's own libSDL3.so.0 and run through sharun, so the
 * names match what Dolphin sees. SDL's headers are not needed: the few functions
 * used are declared below.
 *
 * Usage: mkdd-pads [HINT=VALUE]...   extra SDL hints, e.g. from Dolphin.ini [SDL_Hints]
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef uint32_t SDL_JoystickID;
typedef struct SDL_Gamepad SDL_Gamepad;
typedef struct SDL_Joystick SDL_Joystick;

bool SDL_SetHint(const char *name, const char *value);
bool SDL_Init(uint32_t flags);
void SDL_Quit(void);
void SDL_PumpEvents(void);
void SDL_Delay(uint32_t ms);
void SDL_free(void *mem);
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

#define MAX_PADS 64

int main(int argc, char **argv)
{
	/* Dolphin 2609a's defaults (InputCommon/ControllerInterface/SDL/SDL.cpp).
	 * Some of them change controller names, e.g. combined Joy-Cons. */
	SDL_SetHint("SDL_JOYSTICK_ENHANCED_REPORTS", "1");
	SDL_SetHint("SDL_JOYSTICK_HIDAPI_PS5_PLAYER_LED", "0");
	SDL_SetHint("SDL_JOYSTICK_HIDAPI_COMBINE_JOY_CONS", "1");
	SDL_SetHint("SDL_JOYSTICK_HIDAPI_VERTICAL_JOY_CONS", "0");
	SDL_SetHint("SDL_JOYSTICK_HIDAPI_GAMECUBE", "1");
	for (int i = 1; i < argc; i++) {
		char *eq = strchr(argv[i], '=');
		if (eq == NULL)
			continue;
		*eq = '\0';
		SDL_SetHint(argv[i], eq + 1);
	}

	if (!SDL_Init(SDL_INIT_JOYSTICK | SDL_INIT_HAPTIC | SDL_INIT_GAMEPAD))
		return 1;
	/* HIDAPI controllers can show up a moment after init. */
	for (int i = 0; i < 5; i++) {
		SDL_PumpEvents();
		SDL_Delay(40);
	}

	int count = 0;
	SDL_JoystickID *ids = SDL_GetJoysticks(&count);
	const char *names[MAX_PADS];
	int listed = 0;
	for (int i = 0; ids != NULL && i < count && listed < MAX_PADS; i++) {
		SDL_Gamepad *gc = SDL_OpenGamepad(ids[i]);
		SDL_Joystick *js = SDL_OpenJoystick(ids[i]);
		if (js == NULL)
			continue;
		/* Dolphin skips these the same way. */
		if (SDL_GetNumJoystickButtons(js) > 255 || SDL_GetNumJoystickAxes(js) > 255 ||
		    SDL_GetNumJoystickHats(js) > 255)
			continue;
		const char *name = gc != NULL ? SDL_GetGamepadName(gc) : SDL_GetJoystickName(js);
		if (name == NULL)
			name = "Unknown";
		/* Dolphin numbers devices per name: the first "X" is 0, the next 1. */
		int id = 0;
		for (int j = 0; j < listed; j++)
			if (strcmp(names[j], name) == 0)
				id++;
		names[listed++] = name;
		printf("%d\t%d\t%s\n", id, gc != NULL, name);
	}
	SDL_free(ids);
	fflush(stdout);
	SDL_Quit();
	return 0;
}
