unit DN.Command.Environment;

interface

uses
  DN.Types,
  DN.Command,
  DN.Command.Environment.Intf,
  DN.Package.Intf,
  DN.PackageProvider.Intf,
  DN.DelphiInstallation.Provider.Intf,
  DN.DelphiInstallation.Intf,
  DN.Setup.Intf,
  DN.Package.Finder.Intf,
  DN.Package.Version.Finder.Intf,
  DN.Setup.Dependency.Resolver.Intf,
  DN.Setup.Dependency.Processor.Intf;

type
  TInstalledPackageProviderFactory = reference to function(const AComponentDirectory: string): IDNPackageProvider;

  TDNCommandEnvironment = class(TInterfacedObject, IDNCommandEnvironment)
  private
    FKnownPackages: TArray<TDNCommandClass>;
    FOnlinePackageProvider: IDNPackageProvider;
    FInstalledPackageProvider: IDNPackageProvider;
    FInstalledPackageProviderFactory: TInstalledPackageProviderFactory;
    FInstallationProvider: IDNDelphiInstallationProvider;
    FCurrentDelphi: IDNDelphiInstallation;
    FInteractive: Boolean;
    FVersionFinder: IDNVersionFinder;
    FPanicOnError: Boolean;
    function GetInstalledPackageProvider: IDNPackageProvider;
    function GetKnownCommands: TArray<TDNCommandClass>;
    function GetOnlinePackages: TArray<IDNPackage>;
    function GetInstalledPackages: TArray<IDNPackage>;
    function GetUpdatePackages: TArray<IDNPackage>;
    function GetInteractive: Boolean;
    procedure SetInteractive(const Value: Boolean);
    procedure RequiresCurrentDelphi;
    function GetDelphiName: string;
    procedure SetDelphiName(const Value: string);
    function GetPanicOnError: Boolean;
    procedure SetPanicOnError(const Value: Boolean);
    procedure DefaultMessageHandler(AMessageType: TMessageType; const AMessage: string);
    function GetInstallDependencyResolver: IDNSetupDependencyResolver;
    function GetUninstallDependencyResolver: IDNSetupDependencyResolver;
    function GetDependencyProcessor: IDNSetupDependencyProcessor;
  public
    constructor Create(const AKnownCommands: TArray<TDNCommandClass>;
      const AOnlinePackageProvider: IDNPackageProvider;
      const AInstalledProviderFactory: TInstalledPackageProviderFactory;
      const AInstallationProvider: IDNDelphiInstallationProvider);
    function CreateSetup: IDNSetup;
    function CreatePackageFinder(const APackages: System.TArray<DN.Package.Intf.IDNPackage>): IDNPackageFinder;
    function VersionFinder: IDNVersionFinder;
    function GetDelphiInstallations: TArray<IDNDelphiInstallation>;
  end;

implementation

uses
  Generics.Collections,
  SysUtils,
  IOUtils,
  DN.Installer.Intf,
  DN.Uninstaller.Intf,
  DN.Compiler.Intf,
  DN.BPLService.Intf,
  DN.EnvironmentOptions.Intf,
  DN.ExpertService.Intf,
  DN.Installer.IDE,
  DN.Uninstaller.IDE,
  DN.Compiler.MSBuild,
  DN.BPLService.Registry,
  DN.EnvironmentOptions.Registry,
  DN.ExpertService,
  DN.Setup,
  DN.VariableResolver.Intf,
  DN.VariableResolver.Compiler,
  DN.VariableResolver.Compiler.Factory,
  DN.Package.Finder,
  DN.Package.Version.Finder,
  DN.Setup.Dependency.Resolver.Install,
  DN.Setup.Dependency.Resolver.Uninstall,
  DN.Setup.Dependency.Processor;

const
  CStarterEdition = 'Starter';

{ TDNCommandEnvironment }

constructor TDNCommandEnvironment.Create(
  const AKnownCommands: TArray<TDNCommandClass>; const AOnlinePackageProvider: IDNPackageProvider;
  const AInstalledProviderFactory: TInstalledPackageProviderFactory;
  const AInstallationProvider: IDNDelphiInstallationProvider);
begin
  inherited Create();
  FKnownPackages := AKnownCommands;
  FOnlinePackageProvider := AOnlinePackageProvider;
  FInstalledPackageProviderFactory := AInstalledProviderFactory;
  FInstallationProvider := AInstallationProvider;
  FVersionFinder := TDNVersionFinder.Create();
end;

function TDNCommandEnvironment.CreatePackageFinder(
  const APackages: System.TArray<DN.Package.Intf.IDNPackage>): IDNPackageFinder;
begin
  Result := TDNPackageFinder.Create(APackages);
end;

function TDNCommandEnvironment.CreateSetup: IDNSetup;
var
  LCompiler: IDNCompiler;
  LBPLService: IDNBPLService;
  LEnvironmentOptionsService: IDNEnvironmentOptionsService;
  LExpertService: IDNExpertService;
  LInstaller: IDNInstaller;
  LUninstaller: IDNUninstaller;
  LVariableResolverFactory: TDNCompilerVariableResolverFacory;
begin
  RequiresCurrentDelphi();
  LVariableResolverFactory :=
    function(APlatform: TDNCompilerPlatform; AConfig: TDNCompilerConfig): IVariableResolver
    begin
      Result := TCompilerVariableResolver.Create(APlatform, AConfig, FCurrentDelphi.BDSCommonDir);
    end;
  LCompiler := TDNMSBuildCompiler.Create(LVariableResolverFactory, ExtractFilePath(FCurrentDelphi.Application));
  LBPLService := TDNRegistryBPLService.Create(FCurrentDelphi.Root);
  LEnvironmentOptionsService := TDNRegistryEnvironmentOptionsService.Create(FCurrentDelphi.Root, FCurrentDelphi.SupportedPlatforms);
  LExpertService := TDNExpertService.Create(FCurrentDelphi.Root);
  LInstaller := TDNIDEInstaller.Create(LCompiler, LEnvironmentOptionsService, LBPLService, LVariableResolverFactory, LExpertService);
  LUninstaller := TDNIDEUninstaller.Create(LEnvironmentOptionsService, LBPLService, LExpertService);
  Result := TDNSetup.Create(LInstaller, LUninstaller, FOnlinePackageProvider);
  //Result.ComponentDirectory := TPath.Combine(FCurrentDelphi.BDSCommonDir, 'comps');
  // This is only for "Install"; not used with "list installed" nor "uninstall"
  Result.ComponentDirectory := FCurrentDelphi.ComponentDirectory;
  Result.OnMessage := DefaultMessageHandler;
end;

procedure TDNCommandEnvironment.DefaultMessageHandler(
  AMessageType: TMessageType; const AMessage: string);
var
  LPostFix: string;
begin
  case AMessageType of
    mtNotification: LPostFix := '<info> ';
    mtWarning: LPostFix := '<warning> ';
    mtError: LPostFix := '<error> ';
  end;
  Writeln(LPostFix + AMessage);
end;

function TDNCommandEnvironment.GetDelphiInstallations: TArray<IDNDelphiInstallation>;
begin
  Result := FInstallationProvider.Installations.ToArray;
end;

function TDNCommandEnvironment.GetDelphiName: string;
begin
  RequiresCurrentDelphi();
  Result := FCurrentDelphi.ShortName;
end;

function TDNCommandEnvironment.GetDependencyProcessor: IDNSetupDependencyProcessor;
begin
  Result := TDNSetupDependencyProcessor.Create(CreateSetup());
end;

function TDNCommandEnvironment.GetInstallDependencyResolver: IDNSetupDependencyResolver;
begin
  Result := TDNSetupInstallDependencyResolver.Create(
    function: IDNPackageFinder
    begin
      Result := CreatePackageFinder(GetInstalledPackages());
    end,
    function: IDNPackageFinder
    begin
      Result := CreatePackageFinder(GetOnlinePackages());
    end
  );
end;

function TDNCommandEnvironment.GetInstalledPackageProvider: IDNPackageProvider;
var
  LCompDir: string;
begin
  if not Assigned(FInstalledPackageProvider) then
  begin
    RequiresCurrentDelphi();
    //LCompDir := TPath.Combine(FCurrentDelphi.BDSCommonDir, 'comps');
    // This is for unistall or update
    LCompDir := FCurrentDelphi.ComponentDirectory;
    FInstalledPackageProvider := FInstalledPackageProviderFactory(LCompDir);
  end;
  Result := FInstalledPackageProvider;
end;

function TDNCommandEnvironment.GetInstalledPackages: TArray<IDNPackage>;
begin
  GetInstalledPackageProvider.Reload();
  Result := FInstalledPackageProvider.Packages.ToArray;
end;

function TDNCommandEnvironment.GetInteractive: Boolean;
begin
  Result := FInteractive;
end;

function TDNCommandEnvironment.GetKnownCommands: TArray<TDNCommandClass>;
begin
  Result := FKnownPackages;
end;

function TDNCommandEnvironment.GetOnlinePackages: TArray<IDNPackage>;
begin
  if FOnlinePackageProvider.Packages.Count = 0 then
    FOnlinePackageProvider.Reload;
  Result := FOnlinePackageProvider.Packages.ToArray;
end;

function TDNCommandEnvironment.GetPanicOnError: Boolean;
begin
  Result := FPanicOnError;
end;

function TDNCommandEnvironment.GetUninstallDependencyResolver: IDNSetupDependencyResolver;
begin
  Result := TDNSetupUninstallDependencyResolver.Create(GetInstalledPackages);
end;

function TDNCommandEnvironment.GetUpdatePackages: TArray<IDNPackage>;
var
  LUpdates: TList<IDNPackage>;
  LInstalled, LOnline: IDNPackage;
begin
  LUpdates := TList<IDNPackage>.Create();
  try
    for LInstalled in GetInstalledPackages() do
    begin
      for LOnline in GetOnlinePackages() do
      begin
        if LInstalled.ID = LOnline.ID then
        begin
          if (LOnline.Versions.Count > 0)
            and ((LInstalled.Versions.Count = 0)
              or (LOnline.Versions[0].Value > LInstalled.Versions[0].Value)) then
          begin
            LUpdates.Add(LOnline);
          end;
          Break;
        end;
      end;
    end;
    Result := LUpdates.ToArray;
  finally
    LUpdates.Free;
  end;
end;

procedure TDNCommandEnvironment.RequiresCurrentDelphi;
var
  LInstallation: IDNDelphiInstallation;
begin
  if not Assigned(FCurrentDelphi) then
  begin
    for LInstallation in FInstallationProvider.Installations do
      if not SameText(LInstallation.Edition, CStarterEdition) then
      begin
        FCurrentDelphi := LInstallation;
        Exit;
      end;

    raise ENotSupportedException.Create('No suitable Delphi-Installation detected');
  end;
end;

procedure TDNCommandEnvironment.SetDelphiName(const Value: string);
var
  LInstallation: IDNDelphiInstallation;
begin
  RequiresCurrentDelphi();
  if not SameText(Value, FCurrentDelphi.ShortName) then
  begin
    for LInstallation in FInstallationProvider.Installations do
    begin
      if SameText(LInstallation.ShortName, Value) then
      begin
        if SameText(LInstallation.Edition, CStarterEdition) then
          raise ENotSupportedException.Create('Starter-Editions are not supported');
        FCurrentDelphi := LInstallation;
        //invalidate depending instances
        FInstalledPackageProvider := nil;
        Break;
      end;
    end;
    if not SameText(FCurrentDelphi.ShortName, Value) then
      raise EArgumentException.Create('Unknown Delphi ' + Value);
  end;
end;

procedure TDNCommandEnvironment.SetInteractive(const Value: Boolean);
begin
  FInteractive := Value;
end;

procedure TDNCommandEnvironment.SetPanicOnError(const Value: Boolean);
begin
  FPanicOnError := Value;
end;

function TDNCommandEnvironment.VersionFinder: IDNVersionFinder;
begin
  Result := FVersionFinder;
end;

end.
