defmodule Memo.ExportMarkdown do
  @moduledoc """
  A module to export Obsidian markdown files and assets folders to standard markdown.
  """

  use Flow
  alias Memo.Common.{FileUtils, Frontmatter, LinkUtils, DuckDBUtils}

  def run(vaultpath, exportpath) do
    System.put_env("LC_ALL", "en_US.UTF-8")
    System.cmd("locale", [])

    vaultpath = vaultpath || "vault"
    exportpath = exportpath || "content"

    {vault_dir, mode} =
      if File.dir?(vaultpath) do
        {vaultpath, :directory}
      else
        {Path.dirname(vaultpath), :file}
      end

    ignored_patterns = FileUtils.read_export_ignore_file(Path.join(vault_dir, ".export-ignore"))

    paths = FileUtils.list_files_recursive(vault_dir)
    {all_files, all_assets} = Enum.split_with(paths, &File.regular?/1)

    all_valid_files =
      all_files
      |> Enum.filter(&(not FileUtils.ignored?(&1, ignored_patterns, vault_dir)))

    if mode == :file do
      process_single_file(vaultpath, vault_dir, exportpath, all_valid_files)
    else
      process_directory(all_valid_files, all_assets, vault_dir, exportpath)
    end
  end

  defp process_single_file(vaultpath, vault_dir, exportpath, all_valid_files) do
    normalized_vaultpath = FileUtils.normalize_path(vaultpath)

    if Enum.member?(all_valid_files, normalized_vaultpath) and
         Frontmatter.contains_required_frontmatter_keys?(normalized_vaultpath) do
      process_file(normalized_vaultpath, vault_dir, exportpath, all_valid_files)
    else
      IO.puts(
        "File #{inspect(vaultpath)} does not exist, is ignored, or does not contain required frontmatter keys."
      )
    end
  end

  defp process_directory(all_valid_files, all_assets, vault_dir, exportpath) do
    Flow.from_enumerable(all_valid_files)
    |> Flow.filter(&Frontmatter.contains_required_frontmatter_keys?/1)
    |> Flow.map(&process_file(&1, vault_dir, exportpath, all_valid_files))
    |> Flow.run()

    Flow.from_enumerable(all_assets)
    |> Flow.map(&export_assets_folder(&1, vault_dir, exportpath))
    |> Flow.run()

    # Export the db directory
    export_db_directory("db", exportpath)
  end

  defp export_assets_folder(asset_path, vaultpath, exportpath) do
    if Path.basename(asset_path) == "assets" do
      target_path = replace_path_prefix(asset_path, vaultpath, exportpath)
      copy_directory(asset_path, target_path)
      IO.puts("Exported assets: #{asset_path} -> #{target_path}")
    end
  end

  defp export_db_directory(dbpath, exportpath) do
    if File.dir?(dbpath) do
      export_db_path = Path.join(exportpath, "db")
      copy_directory(dbpath, export_db_path)
      IO.puts("Exported db folder: #{dbpath} -> #{export_db_path}")
    else
      IO.puts("db folder not found at #{dbpath}")
    end
  end

  defp copy_directory(source, destination) do
    lowercase_destination = String.downcase(destination)
    File.mkdir_p!(lowercase_destination)

    File.ls!(source)
    |> Enum.each(fn item ->
      source_path = Path.join(source, item)
      dest_path = Path.join(lowercase_destination, String.downcase(item))

      if File.dir?(source_path) do
        copy_directory(source_path, dest_path)
      else
        File.copy!(source_path, dest_path)
      end
    end)
  end

  defp process_file(file, vaultpath, exportpath, all_files) do
    content = File.read!(file)
    links = LinkUtils.extract_links(content)
    resolved_links = LinkUtils.resolve_links(links, all_files, vaultpath)
    converted_content = LinkUtils.convert_links(content, resolved_links)
    converted_content = process_duckdb_queries(converted_content)

    export_file = replace_path_prefix(file, vaultpath, exportpath)
    lowercase_export_file = String.downcase(export_file)
    export_dir = Path.dirname(lowercase_export_file)
    File.mkdir_p!(export_dir)

    File.write!(lowercase_export_file, converted_content)
    IO.puts("Exported: #{inspect(file)} -> #{inspect(lowercase_export_file)}")
  end

  defp process_duckdb_queries(content) do
    content
    |> process_dsql_tables()
    |> process_dsql_lists()
  end

  defp process_dsql_tables(content) do
    Regex.replace(~r/```dsql-table\n(.*?)```/s, content, fn _, query ->
      case DuckDBUtils.execute_query(query) do
        {:ok, result} -> DuckDBUtils.result_to_markdown_table(result, query)
        {:error, error} -> "Error executing query: #{error}"
      end
    end)
  end

  defp process_dsql_lists(content) do
    Regex.replace(~r/```dsql-list\n(.*?)```/s, content, fn _, query ->
      case DuckDBUtils.execute_query(query) do
        {:ok, result} -> DuckDBUtils.result_to_markdown_list(result, query)
        {:error, error} -> "Error executing query: #{error}"
      end
    end)
  end

  defp replace_path_prefix(path, old_prefix, new_prefix) do
    [old_prefix, new_prefix]
    |> Enum.map(&Path.split/1)
    |> Enum.map(&List.first/1)
    |> then(fn [old, new] -> String.replace_prefix(path, old, new) end)
  end
end
