# frozen_string_literal: true

require "fileutils"
require "mkmf"
require "rbconfig"
require "tmpdir"

abort "zig is required to build fit_kit" unless find_executable("zig")

src = File.join(__dir__, "src", "fit_kit.zig")
profile_src = File.join(__dir__, "src", "profile.zig")
target = "fit_kit.#{RbConfig::CONFIG.fetch("DLEXT")}"
rubyhdrdir = RbConfig::CONFIG.fetch("rubyhdrdir")
rubyarchhdrdir = RbConfig::CONFIG.fetch("rubyarchhdrdir")
libdir = RbConfig::CONFIG.fetch("libdir")
zig_cache_dir = File.join(Dir.tmpdir, "fit_kit_zig_cache")
zig_global_cache_dir = File.join(Dir.tmpdir, "fit_kit_zig_global_cache")

File.write("Makefile", <<~MAKE)
  .PHONY: all install clean

  all: #{target}

  #{target}: #{src} #{profile_src}
  \tzig build-lib #{src} -dynamic -fPIC -O ReleaseSafe -lc --cache-dir #{zig_cache_dir} --global-cache-dir #{zig_global_cache_dir} -I#{rubyhdrdir} -I#{rubyarchhdrdir} -L#{libdir} -lruby -femit-bin=#{target}

  install: all
  \tmkdir -p $(sitearchdir)
  \tcp #{target} $(sitearchdir)/#{target}

  clean:
  \t$(RM) #{target}
MAKE
