# Release tooling for simple-template.
#
#   make test | lint
#   make bump-major | bump-minor | bump-patch | bump-revision   # rewrites the rockspec
#   make publish                                                 # tag + push + luarocks upload
#
# Typical flow:
#   make bump-minor      # rewrites rockspec: version + source.tag + filename
#   git diff             # review
#   git commit -am "release X.Y.0"
#   make publish         # tags vX.Y.0, pushes, uploads to luarocks
#
# `publish` signs the tag if you have a signing key, and reads LUAROCKS_API_KEY
# from the environment if set (otherwise relies on your luarocks config).

PKG      := simple-template
ROCKSPEC := $(wildcard *.rockspec)
VERSION  := $(shell sed -n 's/^version = "\(.*\)"/\1/p' $(ROCKSPEC))
MODVER   := $(firstword $(subst -, ,$(VERSION)))
REV      := $(lastword $(subst -, ,$(VERSION)))
MAJOR    := $(word 1,$(subst ., ,$(MODVER)))
MINOR    := $(word 2,$(subst ., ,$(MODVER)))
PATCH    := $(word 3,$(subst ., ,$(MODVER)))

.DEFAULT_GOAL := help
.PHONY: help test lint bump-major bump-minor bump-patch bump-revision _retarget publish

help:
	@echo "simple-template  $(VERSION)  ($(ROCKSPEC))"
	@echo "targets: test  lint  bump-{major,minor,patch,revision}  publish"

test:
	busted

lint:
	luarocks lint $(ROCKSPEC)

bump-major:
	@$(MAKE) -s _retarget NEW="$$(( $(MAJOR) + 1 )).0.0-1"
bump-minor:
	@$(MAKE) -s _retarget NEW="$(MAJOR).$$(( $(MINOR) + 1 )).0-1"
bump-patch:
	@$(MAKE) -s _retarget NEW="$(MAJOR).$(MINOR).$$(( $(PATCH) + 1 ))-1"
bump-revision:
	@$(MAKE) -s _retarget NEW="$(MODVER)-$$(( $(REV) + 1 ))"

# Rewrite the rockspec to $(NEW): rename the file, set `version` and `source.tag`.
# A revision bump keeps MODVER, so source.tag stays the same (same code, new rockspec).
_retarget:
	@new="$(NEW)"; mod="$${new%-*}"; newfile="$(PKG)-$$new.rockspec"; \
	git mv "$(ROCKSPEC)" "$$newfile" 2>/dev/null || mv "$(ROCKSPEC)" "$$newfile"; \
	sed -i -e 's/^version = .*/version = "'"$$new"'"/' \
	       -e 's/^[[:space:]]*tag = .*/  tag = "v'"$$mod"'"/' "$$newfile"; \
	echo "$(VERSION) -> $$new   ($$newfile, source.tag v$$mod)"; \
	echo "next: review, commit, then 'make publish'"

publish: lint test
	@test -z "$$(git status --porcelain)" || { \
	  echo "working tree dirty -- commit the version bump first"; exit 1; }
	@if git rev-parse -q --verify "refs/tags/v$(MODVER)" >/dev/null; then \
	  echo "tag v$(MODVER) already exists (revision bump?) -- not re-tagging"; \
	else \
	  git tag -s "v$(MODVER)" -m "v$(MODVER)" 2>/dev/null || git tag "v$(MODVER)"; \
	fi
	git push --follow-tags origin HEAD
	luarocks upload $(ROCKSPEC) $${LUAROCKS_API_KEY:+--api-key=$$LUAROCKS_API_KEY}
