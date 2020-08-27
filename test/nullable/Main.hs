{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies       #-}

module Main (main) where

import           Control.Exception.Safe (bracket, catch)
import           Control.Monad (void)
import           Data.Functor.Identity (Identity)
import qualified Data.HashSet as HS
import           Data.Int (Int64)
import           Data.Kind (Type)
import           Data.Text (Text)
import           Database.Beam (Beamable, Columnar, Database, DatabaseSettings,
                                SqlSelect, Table (PrimaryKey, primaryKey),
                                TableEntity, all_, defaultDbSettings,
                                runSelectReturningList, runSelectReturningOne,
                                select)
import           Database.Beam.Backend.SQL.Row (ColumnParseError (ColumnUnexpectedNull),
                                                brreColumn, brreError)
import           Database.Beam.MySQL (ColumnDecodeError (ColumnDecodeError),
                                      MySQL, errorType, runBeamMySQL,
                                      tableNames)
import           Database.MySQL.Base (MySQLConn, Query (Query), close, connect,
                                      execute_)
import           Database.MySQL.Temp (MySQLDB, toConnectInfo, withTempDB)
import           GHC.Generics (Generic)
import           Test.Hspec (Spec, before, describe, hspec, it, shouldBe)

main :: IO ()
main = do
  res <- withTempDB go
  hspec . spec $ res
  where
    go :: MySQLDB -> IO (Maybe ColumnDecodeError)
    go db = bracket (connect . toConnectInfo $ db)
                    close
                    (\conn -> setUpBadDB conn >>
                              runQueryCatching conn)
    runQueryCatching :: MySQLConn -> IO (Maybe ColumnDecodeError)
    runQueryCatching conn =
      catch (runDBDumping2 conn >> runDBDumping conn)
            (\cde@ColumnDecodeError{} -> pure . Just $ cde)
    runDBDumping :: MySQLConn -> IO (Maybe a)
    runDBDumping conn = do
      res <- runBeamMySQL conn . runSelectReturningOne $ query
      case res of
        Nothing  -> pure Nothing
        Just row -> fail ("Got a result when not expecting: " <> show row)
    runDBDumping2 conn = runBeamMySQL conn . runSelectReturningList $ query2
    query :: SqlSelect MySQL (TestT Identity)
    query = select . all_ . _testTestTable $ testDB
    query2 :: SqlSelect MySQL (TestNullsT Identity)
    query2 = select . all_ . _testTestNullsTable $ testDB

-- Helpers

spec :: Maybe ColumnDecodeError -> Spec
spec mRes = before (go mRes) $ do
  describe "Unexpected NULLs" $ do
    it "should contain the name of the table" $ \err ->
      (HS.member "test_table" . tableNames $ err) `shouldBe` True
    it "should indicate the right column" $ \err ->
      (brreColumn . errorType $ err) `shouldBe` Just 1
    it "should say we have an unexpected NULL" $ \err ->
      (isUnexpectedNull . brreError . errorType $ err) `shouldBe` True
  where
    go :: Maybe a -> IO a
    go = \case
      Nothing -> fail "Query did not throw, but should have."
      Just res -> pure res
    isUnexpectedNull :: ColumnParseError -> Bool
    isUnexpectedNull = \case
      ColumnUnexpectedNull -> True
      _ -> False

data TestT (f :: Type -> Type) = TestT
  { _testId   :: Columnar f Int64,
    _testData :: Columnar f Text
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

deriving stock instance Show (TestT Identity)

instance Table TestT where
  data PrimaryKey TestT (f :: Type -> Type) =
    TestTPK (Columnar f Int64)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey = TestTPK . _testId

data TestNullsT (f :: Type -> Type) = TestNullsT
  {
    _testNullsId   :: Columnar f Int64,
    -- This works, even though we have no FromField (Maybe a) instance!
    -- Compiler doesn't even complain, and code runs without issue.
    _testNullsData :: Columnar f (Maybe Text)
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table TestNullsT where
  data PrimaryKey TestNullsT (f :: Type -> Type) =
    TestNullsTPK (Columnar f Int64)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey = TestNullsTPK . _testNullsId

data TestDB (f :: Type -> Type) = TestDB
  {
    _testTestTable      :: f (TableEntity TestT),
    _testTestNullsTable :: f (TableEntity TestNullsT)
  }
  deriving stock (Generic)
  deriving anyclass (Database MySQL)

testDB :: DatabaseSettings MySQL TestDB
testDB = defaultDbSettings
-- DO NOT use this outside of bracket!
setUpBadDB :: MySQLConn -> IO ()
setUpBadDB conn = do
  void . execute_ conn $ "create database test;"
  void . execute_ conn $ "use test"
  void . execute_ conn $ makeTest
  void . execute_ conn $ insertTest
  void . execute_ conn $ makeNullsTest
  void . execute_ conn $ insertNullsTest
  pure ()
  where
    makeTest :: Query
    makeTest = Query $
      "create table test_table (" <>
      "id bigint primary key auto_increment, " <>
      "data varchar(255)" <>
      ");"
    makeNullsTest :: Query
    makeNullsTest = Query $
      "create table test_nulls_table (" <>
      "nulls_id bigint primary key auto_increment, " <>
      "nulls_data varchar(255)" <>
      ");"
    insertTest :: Query
    insertTest = Query $
      "insert into test_table (id, data) " <>
      "values (DEFAULT, NULL);"
    insertNullsTest :: Query
    insertNullsTest = Query $
      "insert into test_nulls_table (nulls_id, nulls_data) " <>
      "values (DEFAULT, NULL), (DEFAULT, 'foo');"

