
<#
.Synopsis
	Tests Update-MongoFiles.ps1 and Get-MongoFile.ps1.
#>

Import-Module Mdbc
Set-StrictMode -Version Latest

task Update-MongoFiles {
	# init
	Connect-Mdbc -NewCollection
	$log = $Database.GetCollection('test_log')
	$null = $log.Drop()
	Remove-Item [z] -Force -Recurse

	# add alien data
	@{Name = 'alien'} | Add-MdbcData
	assert ((Get-MdbcData -Count (New-MdbcQuery Name alien)) -eq 1)

	# update files, no log
	$r = Update-MongoFiles .. -CollectionName test
	assert ($r.Path -like '*\Mdbc')
	assert ($r.Created -gt 100)
	assert ($r.Changed -eq 0)
	assert ($r.Removed -eq 1)
	assert ((Get-MdbcData -Count (New-MdbcQuery Name alien)) -eq 0)
	assert ((Get-MdbcData -Count) -eq $r.Created)

	# new directory and file
	$null = mkdir z
	1 > z\z.txt

	# update
	$r = Update-MongoFiles . -CollectionName test -Log
	assert ($r.Created -eq 2)
	assert ($r.Changed -eq 0)
	assert ($r.Removed -eq 0)

	assert ((Get-MdbcData -Count -Collection $log) -eq 2)
	$1, $2 = Get-MdbcData -Collection $log

	assert ($1._id -like '*\Tests\z')
	assert ($1.Log.Count -eq 1)
	assert ($1.Log[0].Op -eq 0)

	assert ($2._id -like '*\Tests\z\z.txt')
	assert ($2.Log.Count -eq 1)
	assert ($2.Log[0].Op -eq 0)

	# change file
	1 >> z\z.txt

	# update
	$r = Update-MongoFiles . -CollectionName test -Log
	assert ($r.Created -eq 0)
	assert ($r.Changed -eq 1)
	assert ($r.Removed -eq 0)

	assert ((Get-MdbcData -Count -Collection $log) -eq 2)
	$1, $2 = Get-MdbcData -Collection $log

	assert ($1._id -like '*\Tests\z')
	assert ($1.Log.Count -eq 1)
	assert ($1.Log[0].Op -eq 0)

	assert ($2._id -like '*\Tests\z\z.txt')
	assert ($2.Log.Count -eq 2)
	assert ($2.Log[1].Op -eq 1)

	# remove directory and file
	Remove-Item [z] -Force -Recurse

	# update
	$r = Update-MongoFiles . -CollectionName test -Log
	assert ($r.Created -eq 0)
	assert ($r.Changed -eq 0)
	assert ($r.Removed -eq 2)

	assert ((Get-MdbcData -Count -Collection $log) -eq 2)
	$1, $2 = Get-MdbcData -Collection $log

	assert ($1._id -like '*\Tests\z')
	assert ($1.Log.Count -eq 2)
	assert ($1.Log[1].Op -eq 2)

	assert ($2._id -like '*\Tests\z\z.txt')
	assert ($2.Log.Count -eq 3)
	assert ($2.Log[2].Op -eq 2)
}

task Get-MongoFile Update-MongoFiles, {
	$r = @(Get-MongoFile -CollectionName test 'readme|license' | Sort-Object)
	assert (2 -eq $r.Count)
	assert ($r[0] -clike '*\Mdbc\LICENSE.txt')
	assert ($r[1] -clike '*\Mdbc\README.md')

	$r = @(Get-MongoFile -CollectionName test 'readme.md' -Name)
	assert (1 -eq $r.Count)
	assert ($r[0] -clike '*\Mdbc\README.md')
}

task Test-MongoFiles Update-MongoFiles, {
	# minimum time
	$time1 = (Get-ChildItem | Sort-Object LastWriteTime | Select-Object -First 1).LastWriteTime

	Connect-Mdbc

	# Write-Verbose is used because the function returns a number
	function Test-Query($query) {
		Write-Verbose -Verbose $query.ToString()
		$watch = [System.Diagnostics.Stopwatch]::StartNew()
		$count = Get-MdbcData -Count $query
		Write-Verbose -Verbose "$count for $($watch.Elapsed)"
		$count
	}

	$total = $Collection.Count()
	"$total documents"

	"EQ NE"
	$EQReadme = Test-Query (New-MdbcQuery Name Readme.txt)
	$NEReadme = Test-Query (New-MdbcQuery Name -NE Readme.txt)
	assert ($total -eq $EQReadme + $NEReadme) "$total -ne $EQReadme + $NEReadme"

	"IEQ INE"
	$n1 = Test-Query (New-MdbcQuery Name -IEQ README.TXT)
	assert ($n1 -ge $EQReadme)
	$n2 = Test-Query (New-MdbcQuery Name -INE README.TXT)
	assert ($n2 -eq $total - $n1)

	"EQ GT LT"
	$n1 = Test-Query (New-MdbcQuery LastWriteTime $time1)
	$n2 = Test-Query (New-MdbcQuery LastWriteTime -GT $time1)
	$n3 = Test-Query (New-MdbcQuery LastWriteTime -LT $time1)
	assert ($total -eq $n1 + $n2 + $n3)

	"GTE LTE"
	$n2 = Test-Query (New-MdbcQuery LastWriteTime -GTE $time1)
	$n3 = Test-Query (New-MdbcQuery LastWriteTime -LTE $time1)
	assert ($total -eq -$n1 + $n2 + $n3)

	"And"
	$n1 = Test-Query (New-MdbcQuery -And (New-MdbcQuery Name Readme.txt), (New-MdbcQuery LastWriteTime -GT $time1))
	$n2 = Test-Query (New-MdbcQuery -And (New-MdbcQuery Name Readme.txt), (New-MdbcQuery LastWriteTime -LT $time1))
	assert ($EQReadme -eq $n1 + $n2)

	"Or In Match"
	$n1 = Test-Query (New-MdbcQuery -Or (New-MdbcQuery Name Readme.txt), (New-MdbcQuery Name About.txt), (New-MdbcQuery Name LICENSE))
	$n2 = Test-Query (New-MdbcQuery Name -In Readme.txt, About.txt, LICENSE)
	assert ($n1 -eq $n2)
	$n2 = Test-Query (New-MdbcQuery Name -Matches '^(?:Readme\.txt|About\.txt|LICENSE)$')
	assert ($n1 -eq $n2)

	"Matches, ignore case"
	$n1 = Test-Query (New-MdbcQuery Name -Matches '^(?i:Readme\.txt|About\.txt|LICENSE)$')
	$n2 = Test-Query (New-MdbcQuery Name -Matches (New-Object regex '^(?:Readme\.txt|About\.txt|LICENSE)$', IgnoreCase))
	assert ($n1 -eq $n2)

	"Exists Mod Not"
	$MissingLength = Test-Query (New-MdbcQuery Length -NotExists)
	$n1 = Test-Query (New-MdbcQuery Length -Mod 2, 0)
	$n2 = Test-Query (New-MdbcQuery -Not (New-MdbcQuery Length -Mod 2, 1))
	assert ($MissingLength + $n1 -eq $n2)
	$n1 = Test-Query (New-MdbcQuery Length -Mod 2, 1)
	$n2 = Test-Query (New-MdbcQuery -Not (New-MdbcQuery Length -Mod 2, 0))
	assert ($MissingLength + $n1 -eq $n2)

	"Type"
	$n1 = Test-Query (New-MdbcQuery Length -Type Int64)
	assert ($n1 -eq $total - $MissingLength)

	"Where (slow)"
	$n1 = Test-Query (New-MdbcQuery -Where 'this.Length == null')
	assert ($n1 -eq $MissingLength)
}
