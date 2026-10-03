/*
 * A pretend Hercules RMX on the ALSA sequencer, for trying the booth's MIDI path
 * with no hardware: makes a client called "Hercules DJ Console RMX" with one port,
 * and sends the control changes typed on stdin.
 *
 *   gcc -o fake_midi_controller fake_midi_controller.c -lasound
 *   ./fake_midi_controller            # then type lines like:  B0 0B 7F
 *   echo "B0 39 7F" | ./fake_midi_controller --once
 *
 * Any program subscribed to the port (WetOwl's MIDI transport, aseqdump) sees them.
 * Light commands the booth sends back are printed as they arrive.
 */
#include <alsa/asoundlib.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static snd_seq_t *seq;
static int port;

static void send3(unsigned char s, unsigned char d1, unsigned char d2) {
  snd_seq_event_t ev;
  snd_seq_ev_clear(&ev);
  snd_seq_ev_set_source(&ev, port);
  snd_seq_ev_set_subs(&ev);
  snd_seq_ev_set_direct(&ev);
  if ((s & 0xF0) == 0xB0) snd_seq_ev_set_controller(&ev, s & 0x0F, d1, d2);
  else if ((s & 0xF0) == 0x90) snd_seq_ev_set_noteon(&ev, s & 0x0F, d1, d2);
  else if ((s & 0xF0) == 0x80) snd_seq_ev_set_noteoff(&ev, s & 0x0F, d1, d2);
  else return;
  snd_seq_event_output(seq, &ev);
  snd_seq_drain_output(seq);
}

static void drain_in(void) {
  snd_seq_event_t *ev;
  while (snd_seq_event_input_pending(seq, 1) > 0) {
    if (snd_seq_event_input(seq, &ev) < 0) break;
    if (ev->type == SND_SEQ_EVENT_CONTROLLER)
      printf("  <- CC ch%d %02X = %02X (light %s)\n", ev->data.control.channel, ev->data.control.param,
             ev->data.control.value, ev->data.control.value ? "on" : "off");
    else if (ev->type == SND_SEQ_EVENT_NOTEON)
      printf("  <- note ch%d %02X vel %02X\n", ev->data.note.channel, ev->data.note.note, ev->data.note.velocity);
    fflush(stdout);
  }
}

int main(int argc, char **argv) {
  int once = argc > 1 && strcmp(argv[1], "--once") == 0;
  if (snd_seq_open(&seq, "default", SND_SEQ_OPEN_DUPLEX, SND_SEQ_NONBLOCK) < 0) {
    perror("snd_seq_open");
    return 1;
  }
  snd_seq_set_client_name(seq, "Hercules DJ Console RMX");
  port = snd_seq_create_simple_port(seq, "Hercules DJ Console RMX MIDI 1",
                                    SND_SEQ_PORT_CAP_READ | SND_SEQ_PORT_CAP_SUBS_READ |
                                        SND_SEQ_PORT_CAP_WRITE | SND_SEQ_PORT_CAP_SUBS_WRITE,
                                    SND_SEQ_PORT_TYPE_MIDI_GENERIC | SND_SEQ_PORT_TYPE_HARDWARE);
  fprintf(stderr, "fake RMX is client %d port %d; type 'B0 0B 7F' lines\n", snd_seq_client_id(seq), port);

  /* stdin is read with read(2) into our own buffer: stdio would swallow a second
   * line typed with the first and poll(2) would never hear of it. */
  char buf[4096];
  size_t have = 0;
  int stdin_open = 1;
  struct pollfd fds[8];
  int nseq = snd_seq_poll_descriptors_count(seq, POLLIN);
  for (;;) {
    fds[0].fd = stdin_open ? 0 : -1;
    fds[0].events = POLLIN;
    snd_seq_poll_descriptors(seq, fds + 1, nseq, POLLIN);
    if (poll(fds, 1 + nseq, 200) < 0) break;
    if (stdin_open && (fds[0].revents & (POLLIN | POLLHUP))) {
      ssize_t n = read(0, buf + have, sizeof buf - have - 1);
      if (n <= 0) {
        stdin_open = 0;
        if (once) { drain_in(); usleep(200000); drain_in(); return 0; }
      } else {
        have += (size_t)n;
        buf[have] = 0;
        char *start = buf, *nl;
        while ((nl = strchr(start, '\n'))) {
          *nl = 0;
          unsigned s, d1, d2;
          if (sscanf(start, "%x %x %x", &s, &d1, &d2) == 3) send3(s, d1, d2);
          start = nl + 1;
        }
        have = strlen(start);
        memmove(buf, start, have + 1);
      }
    }
    drain_in();
  }
  return 0;
}
