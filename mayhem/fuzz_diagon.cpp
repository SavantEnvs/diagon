// libFuzzer harness for Diagon's translators (Math, Sequence, Tree, Table, Frame, GraphDAG,
// GraphPlanar, Flowchart). Input layout: byte 0 selects the translator, then the translator input
// up to the first NUL, then the translator options (name\nvalue\n lines).
// Ported from the in-tree src/fuzzer.cpp without its stdout dumping. Like upstream's harness it
// leaves out the Grammar translator: kgt's parsers call exit() on malformed input, which would end
// the fuzzing process on nearly every input.
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

#include "translator/Factory.h"

namespace {
std::vector<Translator*> FuzzedTranslators() {
  std::vector<Translator*> out;
  for (auto& translator : TranslatorList()) {
    if (std::strcmp(translator->Identifier(), "Grammar") != 0)
      out.push_back(translator.get());
  }
  return out;
}
}  // namespace

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
  static const std::vector<Translator*> translators = FuzzedTranslators();
  if (size == 0)
    return -1;

  Translator* translator = translators[data[0] % translators.size()];
  ++data;
  --size;

  size_t split = 0;
  while (split < size && data[split])
    ++split;
  std::string input(reinterpret_cast<const char*>(data), split);
  std::string options;
  if (split < size)
    options.assign(reinterpret_cast<const char*>(data) + split + 1,
                   size - split - 1);

  try {
    (void)translator->Translate(input, options);
  } catch (...) {
  }
  return 0;
}
