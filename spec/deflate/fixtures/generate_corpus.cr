# Writes the attack and malformed corpora of spec/deflate/bomb_spec.cr
# from the recipes in corpus.cr:
#
#   crystal-alpha run spec/deflate/fixtures/generate_corpus.cr
#
# The files are committed; run this again after changing a recipe. Streams
# compressed by zlib (the sample payloads) depend on the zlib that wrote
# them, so the committed files, not a fresh run, are the corpus.
require "./corpus"

DeflateCorpus.write_files.each do |path|
  STDOUT << path.sub(DeflateCorpus::DIRECTORY + "/", "") << '\t' << File.size(path) << '\n'
end
