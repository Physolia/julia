JULIAHOME := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
include $(JULIAHOME)/Make.inc

default: $(JULIA_BUILD_MODE) # contains either "debug" or "release"
all: debug release

# sort is used to remove potential duplicates
DIRS := $(sort $(build_bindir) $(build_depsbindir) $(build_libdir) $(build_private_libdir) $(build_libexecdir) $(build_includedir) $(build_includedir)/julia $(build_sysconfdir)/julia $(build_datarootdir)/julia $(build_datarootdir)/julia/stdlib $(build_man1dir))
ifneq ($(BUILDROOT),$(JULIAHOME))
BUILDDIRS := $(BUILDROOT) $(addprefix $(BUILDROOT)/,base src src/flisp src/support src/clangsa ui doc deps stdlib test test/embedding test/llvmpasses)
BUILDDIRMAKE := $(addsuffix /Makefile,$(BUILDDIRS)) $(BUILDROOT)/sysimage.mk
DIRS := $(DIRS) $(BUILDDIRS)
$(BUILDDIRMAKE): | $(BUILDDIRS)
	@# add Makefiles to the build directories for convenience (pointing back to the source location of each)
	@echo '# -- This file is automatically generated in julia/Makefile -- #' > $@
	@echo 'BUILDROOT=$(BUILDROOT)' >> $@
	@echo 'include $(JULIAHOME)$(patsubst $(BUILDROOT)%,%,$@)' >> $@
julia-deps: | $(BUILDDIRMAKE)
configure-y: | $(BUILDDIRMAKE)
configure:
ifeq ("$(origin O)", "command line")
	@if [ "$$(ls '$(BUILDROOT)' 2> /dev/null)" ]; then \
		echo 'WARNING: configure called on non-empty directory $(BUILDROOT)'; \
		read -p "Proceed [y/n]? " answer; \
	else \
		answer=y;\
	fi; \
	[ $$answer = 'y' ] && $(MAKE) configure-$$answer
else
	$(error "cannot rerun configure from within a build directory")
endif
else
configure:
	$(error "must specify O=builddir to run the Julia `make configure` target")
endif

$(foreach dir,$(DIRS),$(eval $(call dir_target,$(dir))))
$(foreach link,base $(JULIAHOME)/test,$(eval $(call symlink_target,$(link),$$(build_datarootdir)/julia,$(notdir $(link)))))

julia_flisp.boot.inc.phony: julia-deps
	@$(MAKE) $(QUIET_MAKE) -C $(BUILDROOT)/src julia_flisp.boot.inc.phony

# Build the HTML docs (skipped if already exists, notably in tarballs)
$(BUILDROOT)/doc/_build/html/en/index.html: $(shell find $(BUILDROOT)/base $(BUILDROOT)/doc \( -path $(BUILDROOT)/doc/_build -o -path $(BUILDROOT)/doc/deps -o -name *_constants.jl -o -name *_h.jl -o -name version_git.jl \) -prune -o -type f -print)
	@$(MAKE) docs

julia-symlink: julia-ui-$(JULIA_BUILD_MODE)
ifeq ($(OS),WINNT)
	@echo '@"%~dp0"\'"$$(echo $(call rel_path,$(BUILDROOT),$(JULIA_EXECUTABLE)) | tr / '\\')" '%*' > $(BUILDROOT)/julia.bat
	chmod a+x $(BUILDROOT)/julia.bat
else
	@ln -sf $(call rel_path,$(BUILDROOT),$(JULIA_EXECUTABLE)) $(BUILDROOT)/julia
endif

julia-deps: | $(DIRS) $(build_datarootdir)/julia/base $(build_datarootdir)/julia/test
	@$(MAKE) $(QUIET_MAKE) -C $(BUILDROOT)/deps

julia-stdlib: | $(DIRS)
	@$(MAKE) $(QUIET_MAKE) -C $(BUILDROOT)/stdlib

julia-base: julia-deps $(build_sysconfdir)/julia/startup.jl $(build_man1dir)/julia.1 $(build_datarootdir)/julia/julia-config.jl
	@$(MAKE) $(QUIET_MAKE) -C $(BUILDROOT)/base

julia-libccalltest: julia-deps
	@$(MAKE) $(QUIET_MAKE) -C $(BUILDROOT)/src libccalltest

julia-libllvmcalltest: julia-deps
	@$(MAKE) $(QUIET_MAKE) -C $(BUILDROOT)/src libllvmcalltest

julia-src-release julia-src-debug : julia-src-% : julia-deps julia_flisp.boot.inc.phony
	@$(MAKE) $(QUIET_MAKE) -C $(BUILDROOT)/src libjulia-$*

julia-ui-release julia-ui-debug : julia-ui-% : julia-src-%
	@$(MAKE) $(QUIET_MAKE) -C $(BUILDROOT)/ui julia-$*

julia-sysimg-ji : julia-stdlib julia-base julia-ui-$(JULIA_BUILD_MODE) | $(build_private_libdir)
	@$(MAKE) $(QUIET_MAKE) -C $(BUILDROOT) -f sysimage.mk sysimg-ji JULIA_EXECUTABLE='$(JULIA_EXECUTABLE)'

julia-sysimg-bc : julia-stdlib julia-base julia-ui-$(JULIA_BUILD_MODE) | $(build_private_libdir)
	@$(MAKE) $(QUIET_MAKE) -C $(BUILDROOT) -f sysimage.mk sysimg-bc JULIA_EXECUTABLE='$(JULIA_EXECUTABLE)'

julia-sysimg-release julia-sysimg-debug : julia-sysimg-% : julia-sysimg-ji julia-ui-%
	@$(MAKE) $(QUIET_MAKE) -C $(BUILDROOT) -f sysimage.mk sysimg-$*

julia-debug julia-release : julia-% : julia-sysimg-% julia-symlink julia-libccalltest julia-libllvmcalltest julia-base-cache

debug release : % : julia-%

docs: julia-sysimg-$(JULIA_BUILD_MODE)
	@$(MAKE) $(QUIET_MAKE) -C $(BUILDROOT)/doc JULIA_EXECUTABLE='$(call spawn,$(JULIA_EXECUTABLE_$(JULIA_BUILD_MODE))) --startup-file=no'

check-whitespace:
ifneq ($(NO_GIT), 1)
	@$(JULIAHOME)/contrib/check-whitespace.sh
else
	$(warn "Skipping whitespace check because git is unavailable")
endif

release-candidate: release testall
	@$(JULIA_EXECUTABLE) $(JULIAHOME)/contrib/add_license_to_files.jl #add license headers
	@#Check documentation
	@$(JULIA_EXECUTABLE) $(JULIAHOME)/doc/NEWS-update.jl #Add missing cross-references to NEWS.md
	@$(MAKE) -C $(BUILDROOT)/doc html doctest=true linkcheck=true
	@$(MAKE) -C $(BUILDROOT)/doc pdf

	@# Check to see if the above make invocations changed anything important
	@if [ -n "$$(git status --porcelain)" ]; then \
		echo "Git repository dirty; Verify and commit changes to the repository, then retry"; \
		exit 1; \
	fi

	@#Check that netload tests work
	@#for test in test/netload/*.jl; do julia $$test; if [ $$? -ne 0 ]; then exit 1; fi; done
	@echo
	@echo To complete the release candidate checklist:
	@echo

	@echo 1. Remove deprecations in base/deprecated.jl
	@echo 2. Update references to the julia version in the source directories, such as in README.md
	@echo 3. Bump VERSION
	@echo 4. Increase SOMAJOR and SOMINOR if needed.
	@echo 5. Create tag, push to github "\(git tag v\`cat VERSION\` && git push --tags\)"		#"` # These comments deal with incompetent syntax highlighting rules
	@echo 6. Clean out old .tar.gz files living in deps/, "\`git clean -fdx\`" seems to work	#"`
	@echo 7. Replace github release tarball with tarballs created from make light-source-dist and make full-source-dist
	@echo 8. Check that 'make && make install && make test' succeed with unpacked tarballs even without Internet access.
	@echo 9. Follow packaging instructions in DISTRIBUTING.md to create binary packages for all platforms
	@echo 10. Upload to AWS, update https://julialang.org/downloads and http://status.julialang.org/stable links
	@echo 11. Update checksums on AWS for tarball and packaged binaries
	@echo 12. Announce on mailing lists
	@echo 13. Change master to release-0.X in base/version.jl and base/version_git.sh as in 4cb1e20
	@echo

$(build_man1dir)/julia.1: $(JULIAHOME)/doc/man/julia.1 | $(build_man1dir)
	@echo Copying in usr/share/man/man1/julia.1
	@mkdir -p $(build_man1dir)
	@cp $< $@

$(build_sysconfdir)/julia/startup.jl: $(JULIAHOME)/etc/startup.jl | $(build_sysconfdir)/julia
	@echo Creating usr/etc/julia/startup.jl
	@cp $< $@

$(build_datarootdir)/julia/julia-config.jl: $(JULIAHOME)/contrib/julia-config.jl | $(build_datarootdir)/julia
	$(INSTALL_M) $< $(dir $@)

$(build_depsbindir)/stringreplace: $(JULIAHOME)/contrib/stringreplace.c | $(build_depsbindir)
	@$(call PRINT_CC, $(HOSTCC) -o $(build_depsbindir)/stringreplace $(JULIAHOME)/contrib/stringreplace.c)

julia-base-cache: julia-sysimg-$(JULIA_BUILD_MODE) | $(DIRS) $(build_datarootdir)/julia
	@JULIA_BINDIR=$(call cygpath_w,$(build_bindir)) $(call spawn, $(JULIA_EXECUTABLE) --startup-file=no $(call cygpath_w,$(JULIAHOME)/etc/write_base_cache.jl) \
		$(call cygpath_w,$(build_datarootdir)/julia/base.cache))

# public libraries, that are installed in $(prefix)/lib
JL_TARGETS := julia
ifeq ($(BUNDLE_DEBUG_LIBS),1)
JL_TARGETS += julia-debug
endif

# private libraries that are installed in $(prefix)/lib/julia and need to be installed to
# the installation prefix for distribution.  Note that libraries provided by BB will not
# be installed in this fashion; they are safely tucked away in the `artifacts` directory.
define register_private_lib
ifeq ($(USE_SYSTEM_$(1)),1)
JL_PRIVATE_LIBS-1 += $(2)
else ifeq ($(USE_BINARYBUILDER_$(1)),1)
JL_PRIVATE_LIBS-2 += $(2)
else
JL_PRIVATE_LIBS-0 += $(2)
endif
endef

$(eval $(call register_private_lib,,libccalltest libllvmcalltest))
ifeq ($(USE_GPL_LIBS), 1)
$(eval $(call register_private_lib,,libsuitesparse_wrapper))
$(eval $(call register_private_lib,SUITESPARSE,libamd libcamd libccolamd libcholmod libcolamd libumfpack libspqr libsuitesparseconfig))
endif
$(eval $(call register_private_lib,PCRE,libpcre2-8))
$(eval $(call register_private_lib,DSFMT,libdSFMT))
$(eval $(call register_private_lib,GMP,libgmp))
$(eval $(call register_private_lib,MPFR,libmpfr))
$(eval $(call register_private_lib,LIBSSH2,libssh2))
$(eval $(call register_private_lib,MBEDTLS,libmbedtls libmbedcrypto libmbedx509))
$(eval $(call register_private_lib,CURL,libcurl))
$(eval $(call register_private_lib,LIBGIT2,libgit2))
$(eval $(call register_private_lib,ZLIB,libz))
ifeq ($(USE_LLVM_SHLIB),1)
$(eval $(call register_private_lib,LLVM,libLLVM libLLVM-9jl))
endif
$(eval $(call register_private_lib,OPENLIBM,libopenlibm))
# Naming mismatches are annoying
USE_SYSTEM_OPENBLAS := $(USE_SYSTEM_BLAS)
$(eval $(call register_private_lib,OPENBLAS,$(LIBBLASNAME)))
ifneq ($(LIBLAPACKNAME),$(LIBBLASNAME))
$(eval $(call register_private_lib,LAPACK,$(LIBLAPACKNAME)))
endif

ifeq ($(OS),Darwin)
ifeq ($(USE_SYSTEM_BLAS),1)
ifeq ($(USE_SYSTEM_LAPACK),0)
JL_PRIVATE_LIBS-0 += libgfortblas
endif
endif
endif

define stringreplace
	$(build_depsbindir)/stringreplace $$(strings -t x - $1 | grep '$2' | awk '{print $$1;}') '$3' 255 "$(call cygpath_w,$1)"
endef


install: $(build_depsbindir)/stringreplace $(BUILDROOT)/doc/_build/html/en/index.html
ifeq ($(BUNDLE_DEBUG_LIBS),1)
	@$(MAKE) $(QUIET_MAKE) all
else
	@$(MAKE) $(QUIET_MAKE) release
endif
	@for subdir in $(bindir) $(datarootdir)/julia/stdlib/$(VERSDIR) $(docdir) $(man1dir) $(includedir)/julia $(libdir) $(private_libdir) $(sysconfdir) $(libexecdir); do \
		mkdir -p $(DESTDIR)$$subdir; \
	done

	$(INSTALL_M) $(build_bindir)/julia$(EXE) $(DESTDIR)$(bindir)/
ifeq ($(BUNDLE_DEBUG_LIBS),1)
	$(INSTALL_M) $(build_bindir)/julia-debug$(EXE) $(DESTDIR)$(bindir)/
endif
ifeq ($(OS),WINNT)
	-$(INSTALL_M) $(filter-out $(build_bindir)/libjulia-debug.dll,$(wildcard $(build_bindir)/*.dll)) $(DESTDIR)$(bindir)/
	-$(INSTALL_M) $(build_libdir)/libjulia.dll.a $(DESTDIR)$(libdir)/

	# We have a single exception; we want 7z.dll to live in libexec, not bin, so that 7z.exe can find it.
	-mv $(DESTDIR)$(bindir)/7z.dll $(DESTDIR)$(libexecdir)/

	# We also have a `julia.exe` and `julia-debug.exe` that live in $(libexecdir)
	$(INSTALL_M) $(build_libexecdir)/julia$(EXE) $(DESTDIR)$(libexecdir)/
ifeq ($(BUNDLE_DEBUG_LIBS),1)
	$(INSTALL_M) $(build_libexecdir)/julia-debug$(EXE) $(DESTDIR)$(libexecdir)/
endif
ifeq ($(BUNDLE_DEBUG_LIBS),1)
	-$(INSTALL_M) $(build_bindir)/libjulia-debug.dll $(DESTDIR)$(bindir)/
	-$(INSTALL_M) $(build_libdir)/libjulia-debug.dll.a $(DESTDIR)$(libdir)/
endif
	-$(INSTALL_M) $(build_bindir)/libopenlibm.dll.a $(DESTDIR)$(libdir)/
else

# Copy over .dSYM directories directly for Darwin
ifneq ($(DARWIN_FRAMEWORK),1)
ifeq ($(OS),Darwin)
	-cp -a $(build_libdir)/libjulia.*.dSYM $(DESTDIR)$(libdir)
	-cp -a $(build_private_libdir)/sys.dylib.dSYM $(DESTDIR)$(private_libdir)
ifeq ($(BUNDLE_DEBUG_LIBS),1)
	-cp -a $(build_libdir)/libjulia-debug.*.dSYM $(DESTDIR)$(libdir)
	-cp -a $(build_private_libdir)/sys-debug.dylib.dSYM $(DESTDIR)$(private_libdir)
endif
endif

	for suffix in $(JL_TARGETS) ; do \
		for lib in $(build_libdir)/lib$${suffix}.*$(SHLIB_EXT)*; do \
			if [ "$${lib##*.}" != "dSYM" ]; then \
				$(INSTALL_M) $$lib $(DESTDIR)$(libdir) ; \
			fi \
		done \
	done
else
	# libjulia in Darwin framework has special location and name
	$(INSTALL_M) $(build_libdir)/libjulia.$(SOMAJOR).$(SOMINOR).dylib $(DESTDIR)$(prefix)/$(framework_dylib)
	@$(DSYMUTIL) -o $(DESTDIR)$(prefix)/$(framework_resources)/$(FRAMEWORK_NAME).dSYM $(DESTDIR)$(prefix)/$(framework_dylib)
	@$(DSYMUTIL) -o $(DESTDIR)$(prefix)/$(framework_resources)/sys.dylib.dSYM $(build_private_libdir)/sys.dylib
ifeq ($(BUNDLE_DEBUG_LIBS),1)
	$(INSTALL_M) $(build_libdir)/libjulia-debug.$(SOMAJOR).$(SOMINOR).dylib $(DESTDIR)$(prefix)/$(framework_dylib)_debug
	@$(DSYMUTIL) -o $(DESTDIR)$(prefix)/$(framework_resources)/$(FRAMEWORK_NAME)_debug.dSYM $(DESTDIR)$(prefix)/$(framework_dylib)_debug
	@$(DSYMUTIL) -o $(DESTDIR)$(prefix)/$(framework_resources)/sys-debug.dylib.dSYM $(build_private_libdir)/sys-debug.dylib
endif
endif

	for suffix in $(JL_PRIVATE_LIBS-0) ; do \
		for lib in $(build_libdir)/$${suffix}.*$(SHLIB_EXT)*; do \
			if [ "$${lib##*.}" != "dSYM" ]; then \
				$(INSTALL_M) $$lib $(DESTDIR)$(private_libdir) ; \
			fi \
		done \
	done
	for suffix in $(JL_PRIVATE_LIBS-1) ; do \
		lib=$(build_private_libdir)/$${suffix}.$(SHLIB_EXT); \
		$(INSTALL_M) $$lib $(DESTDIR)$(private_libdir) ; \
	done
endif
	# Install `7z` into libexec/
	$(INSTALL_M) $(build_libexecdir)/7z$(EXE) $(DESTDIR)$(libexecdir)/

	# Copy public headers
	cp -R -L $(build_includedir)/julia/* $(DESTDIR)$(includedir)/julia
	# Copy system image
	$(INSTALL_M) $(build_private_libdir)/sys.$(SHLIB_EXT) $(DESTDIR)$(private_libdir)
ifeq ($(BUNDLE_DEBUG_LIBS),1)
	$(INSTALL_M) $(build_private_libdir)/sys-debug.$(SHLIB_EXT) $(DESTDIR)$(private_libdir)
endif

	# Copy in all .jl sources as well
	mkdir -p $(DESTDIR)$(datarootdir)/julia/base $(DESTDIR)$(datarootdir)/julia/test
	cp -R -L $(JULIAHOME)/base/* $(DESTDIR)$(datarootdir)/julia/base
	cp -R -L $(JULIAHOME)/test/* $(DESTDIR)$(datarootdir)/julia/test
	cp -Ra $(build_datarootdir)/julia/artifacts $(DESTDIR)$(datarootdir)/julia
	# Copy everything except artifacts, collapsing symlinks
	for f in $(build_datarootdir)/julia/*; do \
		if [ $$(basename $${f}) != artifacts ]; then \
			cp -R -L $${f} $(DESTDIR)$(datarootdir)/julia; \
		fi; \
	done
	# Copy documentation
	cp -R -L $(BUILDROOT)/doc/_build/html $(DESTDIR)$(docdir)/
	# Remove various files which should not be installed
	-rm -f $(DESTDIR)$(datarootdir)/julia/base/version_git.sh
	-rm -f $(DESTDIR)$(datarootdir)/julia/test/Makefile
	-rm -f $(DESTDIR)$(datarootdir)/julia/stdlib/$(VERSDIR)/*/source-extracted
	-rm -f $(DESTDIR)$(datarootdir)/julia/stdlib/$(VERSDIR)/*/build-configured
	-rm -f $(DESTDIR)$(datarootdir)/julia/stdlib/$(VERSDIR)/*/build-compiled
	-rm -f $(DESTDIR)$(datarootdir)/julia/stdlib/$(VERSDIR)/*/build-checked
	# Cleanup artifacts (no full LLVM, objconv, static libs, etc...)
	-rm -f $(DESTDIR)$(datarootdir)/julia/artifacts/*/lib/*.a
	[ -z $(LLVM_jll_TREEHASH) ] || rm -rf $(DESTDIR)$(datarootdir)/julia/artifacts/$(LLVM_jll_TREEHASH)
	[ -z $(Objconv_jll_TREEHASH) ] || rm -rf $(DESTDIR)$(datarootdir)/julia/artifacts/$(Objconv_jll_TREEHASH)
	-rm -rf $(DESTDIR)$(datarootdir)/julia/stdlib/$(VERSDIR)/LLVM_jll
	-rm -rf $(DESTDIR)$(datarootdir)/julia/stdlib/$(VERSDIR)/Objconv_jll

	# Copy in beautiful new man page
	$(INSTALL_F) $(build_man1dir)/julia.1 $(DESTDIR)$(man1dir)/
	# Copy icon and .desktop file
	mkdir -p $(DESTDIR)$(datarootdir)/icons/hicolor/scalable/apps/
	$(INSTALL_F) $(JULIAHOME)/contrib/julia.svg $(DESTDIR)$(datarootdir)/icons/hicolor/scalable/apps/
	-touch -c $(DESTDIR)$(datarootdir)/icons/hicolor/
	mkdir -p $(DESTDIR)$(datarootdir)/applications/
	$(INSTALL_F) $(JULIAHOME)/contrib/julia.desktop $(DESTDIR)$(datarootdir)/applications/
	# Install appdata file
	mkdir -p $(DESTDIR)$(datarootdir)/appdata/
	$(INSTALL_F) $(JULIAHOME)/contrib/julia.appdata.xml $(DESTDIR)$(datarootdir)/appdata/

	# Update RPATH entries and JL_SYSTEM_IMAGE_PATH if $(private_libdir_rel) != $(build_private_libdir_rel)
ifneq ($(private_libdir_rel),$(build_private_libdir_rel))
ifeq ($(OS), Darwin)
ifneq ($(DARWIN_FRAMEWORK),1)
	for j in $(JL_TARGETS) ; do \
		install_name_tool -rpath @executable_path/$(build_private_libdir_rel) @executable_path/$(private_libdir_rel) $(DESTDIR)$(bindir)/$$j; \
		install_name_tool -add_rpath @executable_path/$(build_libdir_rel) @executable_path/$(libdir_rel) $(DESTDIR)$(bindir)/$$j; \
	done
endif
else ifneq (,$(findstring $(OS),Linux FreeBSD))
	for j in $(JL_TARGETS) ; do \
		$(PATCHELF) --set-rpath '$$ORIGIN/$(private_libdir_rel):$$ORIGIN/$(libdir_rel)' $(DESTDIR)$(bindir)/$$j; \
	done
endif

	# Overwrite JL_SYSTEM_IMAGE_PATH in julia library
	if [ $(DARWIN_FRAMEWORK) = 0 ]; then \
		RELEASE_TARGET=$(DESTDIR)$(libdir)/libjulia.$(SHLIB_EXT); \
		DEBUG_TARGET=$(DESTDIR)$(libdir)/libjulia-debug.$(SHLIB_EXT); \
	else \
		RELEASE_TARGET=$(DESTDIR)$(prefix)/$(framework_dylib); \
		DEBUG_TARGET=$(DESTDIR)$(prefix)/$(framework_dylib)_debug; \
	fi; \
	$(call stringreplace,$${RELEASE_TARGET},sys.$(SHLIB_EXT)$$,$(private_libdir_rel)/sys.$(SHLIB_EXT)); \
	if [ $(BUNDLE_DEBUG_LIBS) = 1 ]; then \
		$(call stringreplace,$${DEBUG_TARGET},sys-debug.$(SHLIB_EXT)$$,$(private_libdir_rel)/sys-debug.$(SHLIB_EXT)); \
	fi;

endif
	# On FreeBSD, remove the build's libdir from each library's RPATH
ifeq ($(OS),FreeBSD)
	$(JULIAHOME)/contrib/fixup-rpath.sh "$(PATCHELF)" $(DESTDIR)$(libdir) $(build_libdir)
	$(JULIAHOME)/contrib/fixup-rpath.sh "$(PATCHELF)" $(DESTDIR)$(private_libdir) $(build_libdir)
	$(JULIAHOME)/contrib/fixup-rpath.sh "$(PATCHELF)" $(DESTDIR)$(bindir) $(build_libdir)
	# Set libgfortran's RPATH to ORIGIN instead of GCCPATH. It's only libgfortran that
	# needs to be fixed here, as libgcc_s and libquadmath don't have RPATHs set. If we
	# don't set libgfortran's RPATH, it won't be able to find its friends on systems
	# that don't have the exact GCC port installed used for the build.
	for lib in $(DESTDIR)$(private_libdir)/libgfortran*$(SHLIB_EXT)*; do \
		[ ! -f $$lib ] || $(PATCHELF) --set-rpath '$$ORIGIN' $$lib; \
	done
endif

	mkdir -p $(DESTDIR)$(sysconfdir)
	cp -R $(build_sysconfdir)/julia $(DESTDIR)$(sysconfdir)/

ifeq ($(DARWIN_FRAMEWORK),1)
	$(MAKE) -C $(JULIAHOME)/contrib/mac/framework frameworknoinstall
endif

distclean:
	-rm -fr $(BUILDROOT)/julia-*.tar.gz $(BUILDROOT)/julia*.exe $(BUILDROOT)/julia-$(JULIA_COMMIT)

binary-dist: distclean
ifeq ($(USE_SYSTEM_BLAS),0)
ifeq ($(ISX86),1)
ifneq ($(OPENBLAS_DYNAMIC_ARCH),1)
	@echo OpenBLAS must be rebuilt with OPENBLAS_DYNAMIC_ARCH=1 to use binary-dist target
	@false
endif
endif
endif
ifneq ($(prefix),$(abspath julia-$(JULIA_COMMIT)))
	$(error prefix must not be set for make binary-dist)
endif
ifneq ($(DESTDIR),)
	$(error DESTDIR must not be set for make binary-dist)
endif
	@$(MAKE) -C $(BUILDROOT) -f $(JULIAHOME)/Makefile install
	cp $(JULIAHOME)/LICENSE.md $(BUILDROOT)/julia-$(JULIA_COMMIT)
ifeq ($(OS), Linux)
	# Copy over any bundled ca certs we picked up from the system during buildi
	-cp $(build_datarootdir)/julia/cert.pem $(DESTDIR)$(datarootdir)/julia/
endif
	# Copy in startup.jl files per-platform for binary distributions as well
	# Note that we don't install to sysconfdir: we always install to $(DESTDIR)$(prefix)/etc.
	# If you want to make a distribution with a hardcoded path, you take care of installation
ifeq ($(OS), Darwin)
	-cat $(JULIAHOME)/contrib/mac/startup.jl >> $(DESTDIR)$(prefix)/etc/julia/startup.jl
endif
ifeq ($(OS), WINNT)
	cd $(BUILDROOT)/julia-$(JULIA_COMMIT)/bin && rm -f llvm* llc.exe lli.exe opt.exe LTO.dll bugpoint.exe macho-dump.exe
endif
	cd $(BUILDROOT) && $(TAR) zcvf $(JULIA_BINARYDIST_FILENAME).tar.gz julia-$(JULIA_COMMIT)

exe:
	# run Inno Setup to compile installer
	$(call spawn,$(JULIAHOME)/dist-extras/inno/iscc.exe /DAppVersion=$(JULIA_VERSION) /DSourceDir="$(call cygpath_w,$(BUILDROOT)/julia-$(JULIA_COMMIT))" /DRepoDir="$(call cygpath_w,$(JULIAHOME))" /F"$(JULIA_BINARYDIST_FILENAME)" /O"$(call cygpath_w,$(BUILDROOT))" $(call cygpath_w,$(JULIAHOME)/contrib/windows/build-installer.iss))
	chmod a+x "$(BUILDROOT)/$(JULIA_BINARYDIST_FILENAME).exe"

app:
	$(MAKE) -C contrib/mac/app
	@mv contrib/mac/app/$(JULIA_BINARYDIST_FILENAME).dmg $(BUILDROOT)

darwinframework:
	$(MAKE) -C $(JULIAHOME)/contrib/mac/framework

light-source-dist.tmp: $(BUILDROOT)/doc/_build/html/en/index.html
ifneq ($(BUILDROOT),$(JULIAHOME))
	$(error make light-source-dist does not work in out-of-tree builds)
endif
	# Save git information
	-@$(MAKE) -C $(JULIAHOME)/base version_git.jl.phony

	# Create file light-source-dist.tmp to hold all the filenames that go into the tarball
	echo "base/version_git.jl" > light-source-dist.tmp

	# Download all stdlibs and include the tarball filenames in light-source-dist.tmp
	@$(MAKE) -C stdlib getall NO_GIT=1
	-ls stdlib/srccache/*.tar.gz >> light-source-dist.tmp

	# Exclude git, github and CI config files
	git ls-files | sed -E -e '/^\..+/d' -e '/\/\..+/d' -e '/appveyor.yml/d' >> light-source-dist.tmp
	find doc/_build/html >> light-source-dist.tmp

# Make tarball with only Julia code + stdlib tarballs
light-source-dist: light-source-dist.tmp
	# Prefix everything with "julia-$(commit-sha)/" or "julia-$(version)/" and then create tarball
	# To achieve prefixing, we temporarily create a symlink in the source directory that points back
	# to the source directory.
	sed -e "s_.*_julia-${JULIA_COMMIT}/&_" light-source-dist.tmp > light-source-dist.tmp1
	ln -s . julia-${JULIA_COMMIT}
	tar -cz --no-recursion -T light-source-dist.tmp1 -f julia-$(JULIA_VERSION)_$(JULIA_COMMIT).tar.gz
	rm julia-${JULIA_COMMIT}

source-dist:
	@echo \'source-dist\' target is deprecated: use \'full-source-dist\' instead.

# Make tarball with Julia code plus all dependencies
full-source-dist: light-source-dist.tmp
	# Get all the dependencies downloaded
	@$(MAKE) -C deps getall NO_GIT=1

	# Create file full-source-dist.tmp to hold all the filenames that go into the tarball
	cp light-source-dist.tmp full-source-dist.tmp
	-ls deps/srccache/*.tar.gz deps/srccache/*.tar.bz2 deps/srccache/*.tar.xz deps/srccache/*.tgz deps/srccache/*.zip deps/srccache/*.pem >> full-source-dist.tmp

	# Prefix everything with "julia-$(commit-sha)/" or "julia-$(version)/" and then create tarball
	# To achieve prefixing, we temporarily create a symlink in the source directory that points back
	# to the source directory.
	sed -e "s_.*_julia-${JULIA_COMMIT}/&_" full-source-dist.tmp > full-source-dist.tmp1
	ln -s . julia-${JULIA_COMMIT}
	tar -cz --no-recursion -T full-source-dist.tmp1 -f julia-$(JULIA_VERSION)_$(JULIA_COMMIT)-full.tar.gz
	rm julia-${JULIA_COMMIT}

clean: | $(CLEAN_TARGETS)
	@-$(MAKE) -C $(BUILDROOT)/base clean
	@-$(MAKE) -C $(BUILDROOT)/doc clean
	@-$(MAKE) -C $(BUILDROOT)/src clean
	@-$(MAKE) -C $(BUILDROOT)/ui clean
	@-$(MAKE) -C $(BUILDROOT)/test clean
	@-$(MAKE) -C $(BUILDROOT)/stdlib clean
	-rm -f $(BUILDROOT)/julia
	-rm -f $(BUILDROOT)/*.tar.gz
	-rm -f $(build_depsbindir)/stringreplace \
	   $(BUILDROOT)/light-source-dist.tmp $(BUILDROOT)/light-source-dist.tmp1 \
	   $(BUILDROOT)/full-source-dist.tmp $(BUILDROOT)/full-source-dist.tmp1
	-rm -fr $(build_private_libdir)
# Teporarily add this line to the Makefile to remove extras
	-rm -fr $(build_datarootdir)/julia/extras

cleanall: clean
	@-$(MAKE) -C $(BUILDROOT)/src clean-flisp clean-support
	@-$(MAKE) -C $(BUILDROOT)/deps clean-libuv
	-rm -fr $(build_prefix) $(build_staging)

distcleanall: cleanall
	@-$(MAKE) -C $(BUILDROOT)/stdlib distclean
	@-$(MAKE) -C $(BUILDROOT)/deps distcleanall
	@-$(MAKE) -C $(BUILDROOT)/doc cleanall

.PHONY: default debug release check-whitespace release-candidate \
	julia-debug julia-release julia-stdlib julia-deps julia-deps-libs \
	julia-ui-release julia-ui-debug julia-src-release julia-src-debug \
	julia-symlink julia-base julia-sysimg julia-sysimg-ji julia-sysimg-release julia-sysimg-debug \
	test testall testall1 test test-* test-revise-* \
	clean distcleanall cleanall clean-* \
	run-julia run-julia-debug run-julia-release run \
	install binary-dist light-source-dist.tmp light-source-dist \
	dist full-source-dist source-dist

test: check-whitespace $(JULIA_BUILD_MODE)
	@$(MAKE) $(QUIET_MAKE) -C $(BUILDROOT)/test default JULIA_BUILD_MODE=$(JULIA_BUILD_MODE)

testall: check-whitespace $(JULIA_BUILD_MODE)
	cp $(JULIA_SYSIMG) $(BUILDROOT)/local.$(SHLIB_EXT)
	$(call spawn,$(JULIA_EXECUTABLE) -J $(call cygpath_w,$(BUILDROOT)/local.$(SHLIB_EXT)) -e 'true')
	rm $(BUILDROOT)/local.$(SHLIB_EXT)
	@$(MAKE) $(QUIET_MAKE) -C $(BUILDROOT)/test all JULIA_BUILD_MODE=$(JULIA_BUILD_MODE)

testall1: check-whitespace $(JULIA_BUILD_MODE)
	@env JULIA_CPU_THREADS=1 $(MAKE) $(QUIET_MAKE) -C $(BUILDROOT)/test all JULIA_BUILD_MODE=$(JULIA_BUILD_MODE)

test-%: check-whitespace $(JULIA_BUILD_MODE)
	@([ $$(( $$(date +%s) - $$(date -r $(build_private_libdir)/sys.$(SHLIB_EXT) +%s) )) -le 100 ] && \
		printf '\033[93m    HINT The system image was recently rebuilt. Are you aware of the test-revise-* targets? See CONTRIBUTING.md. \033[0m\n') || true
	@$(MAKE) $(QUIET_MAKE) -C $(BUILDROOT)/test $* JULIA_BUILD_MODE=$(JULIA_BUILD_MODE)

test-revise-%:
	@$(MAKE) $(QUIET_MAKE) -C $(BUILDROOT)/test revise-$* JULIA_BUILD_MODE=$(JULIA_BUILD_MODE)

# download target for some hardcoded windows dependencies
.PHONY: win-extras wine_path
win-extras:
	@$(MAKE) -C $(BUILDROOT)/deps install-p7zip
	mkdir -p $(JULIAHOME)/dist-extras
	cd $(JULIAHOME)/dist-extras && \
	$(JLDOWNLOAD) https://www.jrsoftware.org/download.php/is.exe && \
	chmod a+x is.exe && \
	$(call spawn, $(JULIAHOME)/dist-extras/is.exe /DIR="$(call cygpath_w,$(JULIAHOME)/dist-extras/inno)" /PORTABLE=1 /CURRENTUSER /VERYSILENT)

# various statistics about the build that may interest the user
build-stats-deps:
	@$(MAKE) -C deps install-llvm

build-stats: | build-stats-deps
	@printf $(JULCOLOR)' ==> ./julia binary sizes\n'$(ENDCOLOR)
	$(call spawn,$(LLVM_SIZE) -A $(call cygpath_w,$(build_private_libdir)/sys.$(SHLIB_EXT)) \
		$(call cygpath_w,$(build_shlibdir)/libjulia.$(SHLIB_EXT)) \
		$(call cygpath_w,$(build_bindir)/julia$(EXE)))
	@printf $(JULCOLOR)' ==> ./julia launch speedtest\n'$(ENDCOLOR)
	@time $(call spawn,$(build_bindir)/julia$(EXE) -e '')
	@time $(call spawn,$(build_bindir)/julia$(EXE) -e '')
	@time $(call spawn,$(build_bindir)/julia$(EXE) -e '')
