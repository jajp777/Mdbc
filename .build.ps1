
<#
.Synopsis
	Build script (https://github.com/nightroman/Invoke-Build)

.Description
	How to use this script and build the module:

	*) Copy MongoDB.Bson.dll and MongoDB.Driver.dll from the released package
	to the Module directory. The project Mdbc.csproj assumes they are there.

	*) Get the utility script Invoke-Build.ps1 from here:
		https://github.com/nightroman/Invoke-Build
	Copy it to any directory in the system path. Then set location to the
	directory of this .build.ps1 and invoke the task Build:
	PS> Invoke-Build Build

	This command builds the module and installs it to the $ModuleRoot which is
	the working location of the Mdbc module. The build fails if the module is
	currently in use. Ensure it is not and then repeat.

	The build task Help fails if the help builder Helps is not installed.
	Ignore this or better get and install the module (it is really easy):
	https://github.com/nightroman/Helps

	In order to deal with the latest C# driver sources set the environment
	variable MongoDBCSharpDriverRepo to its repository path. Then all tasks
	*Driver from this script should work as well.
#>

param
(
	$Configuration = 'Release'
)

# Standard location of the Mdbc module (caveat: may not work if MyDocuments is not standard)
$ModuleRoot = Join-Path ([Environment]::GetFolderPath('MyDocuments')) WindowsPowerShell\Modules\Mdbc

# Use MSBuild.
use Framework\v4.0.30319 MSBuild

# Build all.
task Build {
	exec { MSBuild Src\Mdbc.csproj /t:Build /p:Configuration=$Configuration }
}

# Clean all.
task Clean RemoveMarkdownHtml, {
	Remove-Item z, Src\bin, Src\obj, Module\Mdbc.dll, Mdbc.*.zip, *.nupkg -Force -Recurse -ErrorAction 0
}

# Copy all to the module root directory and then build help.
# It is called as the post-build event of Mdbc.csproj.
task PostBuild {
	Copy-Item Src\Bin\$Configuration\Mdbc.dll Module
	exec { robocopy Module $ModuleRoot /s /np /r:0 } (0..3)
},
@{Help=1}

# Build module help by Helps (https://github.com/nightroman/Helps).
task Help -Incremental @{(Get-Item Src\Commands\*, en-US\Mdbc.dll-Help.ps1) = "$ModuleRoot\en-US\Mdbc.dll-Help.xml"} {
	. Helps.ps1
	Convert-Helps en-US\Mdbc.dll-Help.ps1 $Outputs
}

# Test help examples.
task TestHelpExample {
	. Helps.ps1
	Test-Helps en-US\Mdbc.dll-Help.ps1
}

# Test synopsis of each cmdlet and warn about unexpected.
task TestHelpSynopsis {
	Import-Module Mdbc
	Get-Command *-Mdbc* -CommandType cmdlet | Get-Help | .{process{
		if (!$_.Synopsis.EndsWith('.')) {
			Write-Warning "$($_.Name) : unexpected/missing synopsis"
		}
	}}
}

# Update help then run help tests.
task TestHelp Help, TestHelpExample, TestHelpSynopsis

# Copy external scripts from their working location to the project.
# It fails if the scripts are not available.
task UpdateScripts -Partial @{
	{ Get-Command Update-MongoFiles.ps1, Get-MongoFile.ps1 | %{ $_.Definition } } =
	{ process{ "Scripts\$(Split-Path -Leaf $_)" } }
} {
	process{ Copy-Item $_ $$ }
}

# Make a task for each script in the Tests directory and add to the jobs.
task Test @(
	Get-ChildItem Tests -Filter Test-*.ps1 | .{process{
		# add a task
		task $_.Name (Invoke-Expression "{ $($_.FullName) }")
		# add it as a job
		$_.Name
	}}
)

# git pull on the C# driver repo
task PullDriver {
	assert $env:MongoDBCSharpDriverRepo
	Set-Location $env:MongoDBCSharpDriverRepo
	exec { git pull }
}

# Build the C# driver from sources and copy its assemblies to Module
task BuildDriver {
	assert $env:MongoDBCSharpDriverRepo
	exec { MSBuild $env:MongoDBCSharpDriverRepo\CSharpDriver-2010.sln /t:Build /p:Configuration=Release }
	Copy-Item $env:MongoDBCSharpDriverRepo\Driver\bin\Release\*.dll Module
}

# Clean the C# driver sources
task CleanDriver {
	assert $env:MongoDBCSharpDriverRepo
	exec { MSBuild $env:MongoDBCSharpDriverRepo\CSharpDriver-2010.sln /t:Clean /p:Configuration=Release }
}

# Pull the latest driver, build it, then build Mdbc, test and clean all
task Driver PullDriver, BuildDriver, Build, Test, Clean, CleanDriver

# Import markdown tasks ConvertMarkdown and RemoveMarkdownHtml.
# <https://github.com/nightroman/Invoke-Build/wiki/Partial-Incremental-Tasks>
try { Markdown.tasks.ps1 }
catch { task ConvertMarkdown; task RemoveMarkdownHtml }

# Make the package in z\tools for for Zip and NuGet
task Package ConvertMarkdown, @{UpdateScripts=1}, {
	# package directories
	Remove-Item [z] -Force -Recurse
	$null = mkdir z\tools\Mdbc\en-US, z\tools\Mdbc\Scripts

	# copy project files
	Copy-Item -Destination z\tools\Mdbc @(
		'LICENSE.TXT'
		"$ModuleRoot\LICENSE.MongoCSharpDriver.txt"
		"$ModuleRoot\Mdbc.dll"
		"$ModuleRoot\Mdbc.Format.ps1xml"
		"$ModuleRoot\Mdbc.psd1"
		"$ModuleRoot\Mdbc.psm1"
		"$ModuleRoot\MongoDB.Bson.dll"
		"$ModuleRoot\MongoDB.Driver.dll"
	)
	Copy-Item -Destination z\tools\Mdbc\en-US @(
		"$ModuleRoot\en-US\about_Mdbc.help.txt"
		"$ModuleRoot\en-US\Mdbc.dll-Help.xml"
	)
	Copy-Item -Destination z\tools\Mdbc\Scripts @(
		'Scripts\Get-MongoFile.ps1'
		'Scripts\Update-MongoFiles.ps1'
	)

	# move generated files
	Move-Item -Destination z\tools\Mdbc @(
		'README.htm'
	)
}

# Get version from the assembly and sets $script:Version
task Version {
	assert ((Get-Item $ModuleRoot\Mdbc.dll).VersionInfo.FileVersion -match '^(\d+\.\d+\.\d+)')
	$script:Version = $matches[1]
}

# Make the zip package
task Zip Package, Version, {
	Set-Location z\tools
	exec { & 7z a ..\..\Mdbc.$Version.zip * }
}

# Make the NuGet package
task NuGet Package, Version, {
	# nuspec
	Set-Content z\Package.nuspec @"
<?xml version="1.0"?>
<package xmlns="http://schemas.microsoft.com/packaging/2010/07/nuspec.xsd">
	<metadata>
		<id>Mdbc</id>
		<version>$Version</version>
		<authors>Roman Kuzmin</authors>
		<owners>Roman Kuzmin</owners>
		<projectUrl>https://github.com/nightroman/Mdbc</projectUrl>
		<licenseUrl>http://www.apache.org/licenses/LICENSE-2.0</licenseUrl>
		<requireLicenseAcceptance>false</requireLicenseAcceptance>
		<summary>
Mdbc is the Windows PowerShell module built on top of the official MongoDB C#
driver. It provides a few cmdlets and PowerShell friendly features for basic
operations on MongoDB data.
		</summary>
		<description>
Mdbc is the Windows PowerShell module built on top of the official MongoDB C#
driver. It provides a few cmdlets and PowerShell friendly features for basic
operations on MongoDB data.
		</description>
		<tags>Mongo MongoDB PowerShell Module</tags>
	</metadata>
</package>
"@
	# pack
	exec { NuGet pack z\Package.nuspec }
}

# Check the files before commit. Called by .git/hooks/pre-commit.
task pre-commit {
	foreach ($file in git status -s) {
		$file
		if ($file -notmatch '\.(cs|csproj|md|ps1|psd1|psm1|ps1xml|sln|txt|xml|gitignore)$') {
			throw "Commit is not allowed: '$file'."
		}
	}
}

# Build, test and clean all.
task . Build, Test, TestHelp, Clean
