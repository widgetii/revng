This page is a contributor-oriented overview of how the major moving parts of rev.ng fit together: the QEMU/libtcg-based lifter, LLVM IR, the MLIR-based Clift dialect, and the YAML [model](../user-manual/key-concepts/model.md) that ties everything together.

## Diagram

```text
    ┌─────────┐
    │ Binary  │
    └────┬────┘
         ↓
   ┌──────────────────────────────────┐         ┌────────────────────────┐
   │ Lift  (lib/Lift)                 │         │       MODEL            │
   │  ├─ libtcg-<arch>.so  (dlopen)   │ ─arch──→│  YAML, source of truth │
   │  └─ early-linked.c, support.c    │         │  (user-editable)       │
   │     → LLVM bitcode, linked in    │         │                        │
   └─────────────────┬────────────────┘         │  schema:               │
                     │                          │   include/revng/Model/ │
                     ↓                          │   model-schema.yml     │
            ┌────────────────┐                  │                        │
            │   LLVM IR      │ ←── analyses ───→│                        │
            │   (root fn)    │    read+write    │                        │
            └────────┬───────┘                  └────────────┬───────────┘
                     │                                       │
                     │  Analyses (LLVM passes):              │ tuple-tree
                     │   EarlyFunctionAnalysis,              │ generator
                     │   DataLayoutAnalysis, ABI, ...        │
                     │   write recovered facts → Model       ↓
                     │                              ┌──────────────────┐
                     │                              │  Generated:      │
            ┌────────┴─────────┐                    │   C++ headers    │
            │                  │                    │   Python (model) │
       (legacy LLVM       (Clift path)              │   TypeScript     │
        decompile)             │                    └──────────────────┘
            │                  ↓
            │         ┌──────────────────┐
            │         │  Clift dialect   │ ← lib/Clift, lib/Clifter,
            │         │  (mlir::clift)   │   lib/CliftPipes
            │         │                  │
            │         │  CliftTransforms │
            │         └────────┬─────────┘
            │                  │ CliftEmitC  (lib/CliftEmitC)
            ↓                  ↓
       ┌────────────────────────────────┐
       │   Decompiled C  /  PTML        │
       │   (artifact: decompile.tar.gz) │
       └────────────────────────────────┘

   Pipeline framework  (lib/Pipeline + lib/Pipes) orchestrates every
   step above; the concrete graph lives in
   share/revng/pipelines/revng-pipelines.yml
```

## Components

* **Lift** — `lib/Lift/Lift.cpp`; libtcg loader at `lib/Lift/LibTcg.cpp`. Per-architecture runtime modules (`share/revng/early-linked.c`, `share/revng/support.c`) are compiled to LLVM bitcode and linked into the lifted IR.
* **Model** — root type `include/revng/Model/Binary.h`; schema `include/revng/Model/model-schema.yml`. The model is the user-editable source of truth and is shared state across every analysis and emission step.
* **Tuple-tree generator** — `scripts/tuple_tree_generator/`, driven by `share/revng/cmake/TupleTreeGenerator.cmake`. Consumes the schema and emits matching C++, Python and TypeScript bindings into the build tree.
* **Analyses** — `lib/EarlyFunctionAnalysis/`, `lib/DataLayoutAnalysis/`, `lib/ABI/`, `lib/HelperArgumentsAnalysis/`, and others. They read the LLVM IR and write recovered facts back into the model (function boundaries, prototypes, types, ABI information).
* **Clift import** — `lib/Clifter/Clifter.cpp` does the per-function LLVM-to-Clift lowering; `lib/CliftPipes/Clifter.cpp` exposes it as a pipe; `lib/CliftPipes/ImportTypes.cpp` imports model types into the Clift context.
* **Clift transforms and C emission** — `lib/Clift/` holds the dialect and its passes; `lib/CliftEmitC/CEmitter.cpp` is the [PTML](ptml.md)-producing C printer.
* **Pipeline framework** — `lib/Pipeline/` and `lib/Pipes/` provide the generic step/pipe/container machinery; the concrete graph (steps, artifacts, [MIME types](mime-types.md)) is declared in `share/revng/pipelines/revng-pipelines.yml`.

## Two decompilation paths

Both a legacy LLVM-direct path and the newer Clift path produce a decompiled-C+PTML artifact, and both are wired up in `share/revng/pipelines/revng-pipelines.yml`. They diverge late — around the stack-access segregation step — and converge again at the `decompile` artifact. The legacy path goes from cleaned-up LLVM IR straight to PTML; the Clift path lowers LLVM into the `mlir::clift` dialect, runs `CliftTransforms`, and then emits via `CliftEmitC`.

The Clift path is the direction the project is moving in: it represents decompiled code as a structured MLIR dialect rather than as low-level LLVM IR plus side metadata, which makes high-level transforms (and consistency checks against the model) significantly more tractable. New work on the decompilation backend should generally happen on the Clift side.
