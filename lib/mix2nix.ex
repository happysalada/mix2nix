defmodule Mix2nix do
	def process(filename) do
		filename
		|> read
		|> expression_set
	end

	def expression_set(deps) do
		deps
		|> Enum.map(fn {_, v} -> nix_expression(deps, v) end)
		|> Enum.reject(fn x -> x == "" end)
		|> Enum.join("\n")
		|> String.trim("\n")
		|> wrap
	end

	defp read(filename) do
		opts = [file: filename, warn_on_unnecessary_quotes: false]

		with {:ok, contents} <- File.read(filename),
		     {:ok, quoted} <- Code.string_to_quoted(contents, opts),
		     {%{} = lock, _} <- Code.eval_quoted(quoted, opts) do
			lock
		else
			{:error, posix} when is_atom(posix) ->
				raise to_string(:file.format_error(posix))

			{:error, {line, error, token}} when is_integer(line) ->
				raise "Error on line #{line}: #{error} (#{inspect(token)})"
		end
	end

	def is_required(allpkgs, [ hex: name, repo: _, optional: optional ]) do
		Map.has_key?(allpkgs, name) or ! optional
	end

	def dep_string(allpkgs, deps) do
		depString =
			deps
			|> Enum.filter(fn x -> is_required(allpkgs, elem(x, 2)) end)
			|> Enum.map(fn x -> Atom.to_string(elem(x, 0)) end)
			|> Enum.join(" ")

		if String.length(depString) > 0 do
			"[ " <> depString <> " ]"
		else
			"[]"
		end
	end

	def get_build_env(builders, pkgname) do
		cond do
			pkgname == "cowboy" ->
				"buildErlangMk"
			pkgname == "jose" ->
				"buildMix"
			Enum.member?(builders, :rebar3) ->
				"buildRebar3"
			Enum.member?(builders, :mix) ->
				"buildMix"
			Enum.member?(builders, :make) ->
				"buildErlangMk"
			true ->
				"buildRebar3"
		end
	end

	def get_hash(name, version) do
		url = "https://repo.hex.pm/tarballs/#{name}-#{version}.tar"
		{ result, status } = System.cmd("nix-prefetch-url", [url])

		case status do
			0 -> String.trim(result)
			_ -> raise "Use of nix-prefetch-url failed."
		end
	end

	def nix_expression(
		allpkgs,
		{:hex, name, version, _hash, builders, deps, "hexpm", _hash2}
	), do: get_hexpm_expression(allpkgs, name, version, builders, deps)

	def nix_expression(
		allpkgs,
		{:hex, name, version, _hash, builders, deps, "hexpm"}
	), do: get_hexpm_expression(allpkgs, name, version, builders, deps)

	def nix_expression(_allpkgs, _pkg) do
		""
	end

	defp get_hexpm_expression(allpkgs, name, version, builders, deps) do
		name = Atom.to_string(name)
		buildEnv = get_build_env(builders, name)
		sha256 = get_hash(name, version)
		deps = dep_string(allpkgs, deps)

		"""
				#{name} = #{buildEnv} rec {
					name = "#{name}";
					version = "#{version}";

					src = fetchHex {
						pkg = "${name}";
						version = "${version}";
						sha256 = "#{sha256}";
					};

					beamDeps = #{deps};
				};
		"""
	end

	defp wrap(pkgs) do
		"""
		{ lib, beamPackages, overrides ? (x: y: {}) }:

		let
			buildRebar3 = lib.makeOverridable beamPackages.buildRebar3;
			buildMix = lib.makeOverridable beamPackages.buildMix;
			buildErlangMk = lib.makeOverridable beamPackages.buildErlangMk;

			self = packages // (overrides self packages);

			packages = with beamPackages; with self; {
		#{pkgs}
			};
		in self
		"""
	end
end
