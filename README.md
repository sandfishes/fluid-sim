This is a 2D fluid simulation using Vulkan.
The UI is a combination of Clay and the Odin vendored font-stash.

Shaders are written in slang, and the odin slang project must be placed inside the gpu folder.
UI layout is handled by clay, the odin-clay bindings from the clay repo must be added inside the ui folder.

Slang and Vulkan must be installed. There may also be some shenanigans with LD linking the correct dylibs especially on Linux.
