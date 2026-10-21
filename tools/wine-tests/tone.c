/* tone.c — a sine tone through waveOut, to check Wine's sound path on Haiku (winmm → mmdevapi → winehaiku.drv →
 * BSoundPlayer → the system mixer). Plays argv[2] Hz (default 1000) for argv[1] seconds (default 3), stereo
 * 44100 Hz, as 16-bit PCM or, with argv[3] = "float", 32-bit float; prints "TONE " lines: the device, the format,
 * the buffers played and the time it took. Exit status 0 when every buffer came back done within twice the tone's
 * length. Built for arm64 and for x86 (WoW64 under the emulator) by scripts/build-wine.sh. */
#include <windows.h>
#include <mmsystem.h>
#include <mmreg.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define RATE 44100
#define CHANNELS 2
#define BUFFERS 4
#define BUFFER_MS 100

int main(int argc, char **argv)
{
	double seconds = argc > 1 ? atof(argv[1]) : 3, hz = argc > 2 ? atof(argv[2]) : 1000, phase = 0;
	BOOL use_float = argc > 3 && !strcmp(argv[3], "float");
	DWORD frames = RATE * BUFFER_MS / 1000, total = (DWORD)(seconds * 1000 / BUFFER_MS), queued = 0, done = 0;
	WAVEFORMATEX fmt = { 0 };
	WAVEOUTCAPSA caps;
	WAVEHDR hdr[BUFFERS];
	HWAVEOUT wave;
	MMRESULT err;
	HANDLE event;
	DWORD start, elapsed;
	UINT devices;

	devices = waveOutGetNumDevs();
	printf("TONE devices %u\n", devices);
	if (waveOutGetDevCapsA(WAVE_MAPPER, &caps, sizeof(caps)) == MMSYSERR_NOERROR)
		printf("TONE device \"%s\"\n", caps.szPname);

	fmt.wFormatTag = use_float ? WAVE_FORMAT_IEEE_FLOAT : WAVE_FORMAT_PCM;
	fmt.nChannels = CHANNELS;
	fmt.nSamplesPerSec = RATE;
	fmt.wBitsPerSample = use_float ? 32 : 16;
	fmt.nBlockAlign = fmt.nChannels * fmt.wBitsPerSample / 8;
	fmt.nAvgBytesPerSec = fmt.nSamplesPerSec * fmt.nBlockAlign;

	event = CreateEventA(NULL, FALSE, FALSE, NULL);
	err = waveOutOpen(&wave, WAVE_MAPPER, &fmt, (DWORD_PTR)event, 0, CALLBACK_EVENT);
	if (err != MMSYSERR_NOERROR) {
		printf("TONE waveOutOpen failed: %u\n", err);
		return 1;
	}
	printf("TONE playing %.0f Hz for %.1f s, %s %lu Hz %u channels\n", hz, seconds,
		use_float ? "float32" : "s16", fmt.nSamplesPerSec, fmt.nChannels);

	memset(hdr, 0, sizeof(hdr));
	for (int i = 0; i < BUFFERS; i++) {
		hdr[i].dwBufferLength = frames * fmt.nBlockAlign;
		hdr[i].lpData = malloc(hdr[i].dwBufferLength);
	}

	start = GetTickCount();
	while (done < total) {
		for (int i = 0; i < BUFFERS; i++) {
			WAVEHDR *h = &hdr[i];
			if ((h->dwFlags & WHDR_PREPARED) && (h->dwFlags & WHDR_DONE)) {
				waveOutUnprepareHeader(wave, h, sizeof(*h));
				done++;
			}
			if ((h->dwFlags & WHDR_PREPARED) || queued == total)
				continue;
			for (DWORD f = 0; f < frames; f++) {
				double v = 0.25 * sin(phase);
				phase += 2 * M_PI * hz / RATE;
				for (int c = 0; c < CHANNELS; c++) {
					if (use_float)
						((float *)h->lpData)[f * CHANNELS + c] = (float)v;
					else
						((short *)h->lpData)[f * CHANNELS + c] = (short)(v * 32767);
				}
			}
			phase = fmod(phase, 2 * M_PI);
			h->dwFlags = 0;
			waveOutPrepareHeader(wave, h, sizeof(*h));
			waveOutWrite(wave, h, sizeof(*h));
			queued++;
		}
		if (done == total || GetTickCount() - start > seconds * 2000 + 2000)
			break;
		WaitForSingleObject(event, 500);
	}
	elapsed = GetTickCount() - start;

	waveOutReset(wave);
	for (int i = 0; i < BUFFERS; i++) {
		if (hdr[i].dwFlags & WHDR_PREPARED)
			waveOutUnprepareHeader(wave, &hdr[i], sizeof(hdr[i]));
		free(hdr[i].lpData);
	}
	waveOutClose(wave);
	CloseHandle(event);

	printf("TONE played %lu of %lu buffers (%u ms each) in %lu ms\n", done, total, BUFFER_MS, elapsed);
	if (done < total || elapsed > seconds * 2000) {
		printf("TONE FAIL\n");
		return 1;
	}
	printf("TONE OK\n");
	return 0;
}
