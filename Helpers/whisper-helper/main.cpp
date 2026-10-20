// hiveminds-whisper: a tiny helper process that keeps a whisper.cpp model loaded and
// transcribes audio that HiveMinds pipes to it. It runs only while dictation is in use.
//
// Usage: hiveminds-whisper <model.bin> <language|auto> [prompt]
// Protocol (stdin -> stdout, repeated until stdin closes):
//   in:  uint32 little-endian sample count, then that many float32 samples (16 kHz mono)
//   out: one line of text, then a newline. An empty line means nothing was heard.
// The helper prints "ready" once the model has loaded. Errors go to stderr.

#include "whisper.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <string>
#include <thread>
#include <vector>

static void quiet_log(enum ggml_log_level, const char *, void *) {}

static bool read_exact(void * dst, size_t n) {
    return fread(dst, 1, n, stdin) == n;
}

int main(int argc, char ** argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <model> <language|auto> [prompt]\n", argv[0]);
        return 2;
    }
    const std::string language = argv[2];
    const std::string prompt   = argc > 3 ? argv[3] : "";

    whisper_log_set(quiet_log, nullptr);
    whisper_context_params cparams = whisper_context_default_params();
    cparams.use_gpu = false;
    whisper_context * ctx = whisper_init_from_file_with_params(argv[1], cparams);
    if (!ctx) {
        fprintf(stderr, "could not load model %s\n", argv[1]);
        return 1;
    }
    printf("ready\n");
    fflush(stdout);

    const int threads = std::max(1, std::min(8, (int) std::thread::hardware_concurrency() - 2));
    std::vector<float> samples;

    for (;;) {
        uint32_t count = 0;
        if (!read_exact(&count, sizeof(count))) break;
        if (count > 16000u * 60u * 10u) { fprintf(stderr, "clip too long\n"); return 1; }
        samples.resize(count);
        if (count > 0 && !read_exact(samples.data(), count * sizeof(float))) break;

        whisper_full_params p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
        p.n_threads        = threads;
        p.no_context       = true;
        p.no_timestamps    = true;
        p.single_segment   = false;
        p.print_progress   = false;
        p.print_realtime   = false;
        p.print_special    = false;
        p.print_timestamps = false;
        p.suppress_blank   = true;
        p.suppress_nst     = true;
        p.language         = language.c_str();
        p.detect_language  = false;
        p.initial_prompt   = prompt.empty() ? nullptr : prompt.c_str();

        std::string text;
        if (count > 0 && whisper_full(ctx, p, samples.data(), (int) count) == 0) {
            const int n = whisper_full_n_segments(ctx);
            for (int i = 0; i < n; ++i) {
                text += whisper_full_get_segment_text(ctx, i);
            }
        }
        for (char & c : text) {
            if (c == '\n' || c == '\r') c = ' ';
        }
        printf("%s\n", text.c_str());
        fflush(stdout);
    }

    whisper_free(ctx);
    return 0;
}
