// RGB standard library
// Written in 2019-2022 by
//     Dr. Maxim Orlovsky <orlovsky@lnp-bp.org>
//
// To the extent possible under law, the author(s) have dedicated all
// copyright and related and neighboring rights to this software to
// the public domain worldwide. This software is distributed without
// any warranty.
//
// You should have received a copy of the MIT License
// along with this software.
// If not, see <https://opensource.org/licenses/MIT>.

use std::path::PathBuf;
use std::{fs, io};

use bitcoin::hashes::hex::ToHex;
use bp::dbc::{Anchor, AnchorId};
use commit_verify::lnpbp4::MerkleBlock;
use rgb::prelude::*;

use super::Store;
use crate::error::{BootstrapError, ServiceErrorDomain};
use crate::util::file::*;

#[derive(Debug, Display, Error, From)]
#[display(Debug)]
pub enum DiskStorageError {
    #[from]
    Io(io::Error),

    #[from(bitcoin::hashes::Error)]
    HashName,

    #[from]
    Encoding(strict_encoding::Error),

    #[from(bitcoin::hashes::hex::Error)]
    #[from(rgb::bech32::Error)]
    BrokenFilenames,
}

impl From<DiskStorageError> for ServiceErrorDomain {
    fn from(err: DiskStorageError) -> Self { ServiceErrorDomain::Storage(err.to_string()) }
}

impl From<DiskStorageError> for BootstrapError {
    fn from(_: DiskStorageError) -> Self { BootstrapError::StorageError }
}

#[derive(Clone, PartialEq, Eq, Hash, Debug, Display)]
#[display(Debug)]
pub struct DiskStorageConfig {
    pub data_dir: PathBuf,
}

impl DiskStorageConfig {
    pub const RGB_FILE_EXT: &'static str = "rgb";

    #[inline]
    pub fn schemata_dir(&self) -> PathBuf { self.data_dir.join("schemata") }

    #[inline]
    pub fn geneses_dir(&self) -> PathBuf { self.data_dir.join("geneses") }

    #[inline]
    pub fn anchors_dir(&self) -> PathBuf { self.data_dir.join("anchors") }

    #[inline]
    pub fn transitions_dir(&self) -> PathBuf { self.data_dir.join("transitions") }

    #[inline]
    pub fn extensions_dir(&self) -> PathBuf { self.data_dir.join("extensions") }

    #[inline]
    pub fn schema_filename(&self, schema_id: &SchemaId) -> PathBuf {
        self.schemata_dir()
            .join(schema_id.to_bech32().to_string())
            .with_extension(Self::RGB_FILE_EXT)
    }

    #[inline]
    pub fn genesis_filename(&self, contract_id: &ContractId) -> PathBuf {
        self.geneses_dir()
            .join(contract_id.to_bech32().to_string())
            .with_extension(Self::RGB_FILE_EXT)
    }

    #[inline]
    pub fn anchor_filename(&self, anchor_id: &AnchorId) -> PathBuf {
        self.anchors_dir()
            .join(anchor_id.to_hex())
            .with_extension(Self::RGB_FILE_EXT)
    }

    #[inline]
    pub fn transition_filename(&self, node_id: &NodeId) -> PathBuf {
        self.transitions_dir()
            .join(node_id.to_hex())
            .with_extension(Self::RGB_FILE_EXT)
    }

    #[inline]
    pub fn extension_filename(&self, node_id: &NodeId) -> PathBuf {
        self.extensions_dir()
            .join(node_id.to_hex())
            .with_extension(Self::RGB_FILE_EXT)
    }

    #[inline]
    pub fn schema_names(&self) -> Result<Vec<String>, io::Error> {
        Ok(
            read_dir_filenames(self.schemata_dir(), Some(Self::RGB_FILE_EXT))?
                .into_iter()
                .map(|name| String::from(name))
                .collect(),
        )
    }

    #[inline]
    pub fn genesis_names(&self) -> Result<Vec<String>, io::Error> {
        Ok(
            read_dir_filenames(self.geneses_dir(), Some(Self::RGB_FILE_EXT))?
                .into_iter()
                .map(|name| String::from(name))
                .collect(),
        )
    }
}

/// Keeps all source/binary RGB contract data, stash etc
#[derive(Debug, Display)]
#[display(Debug)]
pub struct DiskStorage {
    config: DiskStorageConfig,
}

impl DiskStorage {
    pub fn new(config: DiskStorageConfig) -> Result<Self, DiskStorageError> {
        debug!("Instantiating RGB storage (disk storage) ...");

        let data_dir = config.data_dir.clone();
        if !data_dir.exists() {
            debug!(
                "RGB data directory '{:?}' is not found; creating one",
                data_dir
            );
            fs::create_dir_all(data_dir)?;
        }
        let schemata_dir = config.schemata_dir();
        if !schemata_dir.exists() {
            debug!(
                "RGB schemata directory '{:?}' is not found; creating one",
                schemata_dir
            );
            fs::create_dir_all(schemata_dir)?;
        }
        let geneses_dir = config.geneses_dir();
        if !geneses_dir.exists() {
            debug!(
                "RGB geneses data directory '{:?}' is not found; creating one",
                geneses_dir
            );
            fs::create_dir_all(geneses_dir)?;
        }

        let anchors_dir = config.anchors_dir();
        if !anchors_dir.exists() {
            debug!(
                "RGB anchor data directory '{:?}' is not found; creating one",
                anchors_dir
            );
            fs::create_dir_all(anchors_dir)?;
        }

        let transitions_dir = config.transitions_dir();
        if !transitions_dir.exists() {
            debug!(
                "RGB state transition data directory '{:?}' is not found; creating one",
                transitions_dir
            );
            fs::create_dir_all(transitions_dir)?;
        }

        Ok(Self { config })
    }
}

impl Store for DiskStorage {
    type Error = DiskStorageError;

    fn schema_ids(&self) -> Result<Vec<SchemaId>, Self::Error> {
        self.config
            .schema_names()?
            .into_iter()
            .try_fold(vec![], |mut list, name| {
                let name = name.replace(".rgb", "");
                list.push(SchemaId::from_bech32_str(&name)?);
                Ok(list)
            })
    }

    #[inline]
    fn schema(&self, id: &SchemaId) -> Result<Schema, Self::Error> {
        Ok(Schema::read_file(self.config.schema_filename(id))?)
    }

    #[inline]
    fn has_schema(&self, id: &SchemaId) -> Result<bool, Self::Error> {
        Ok(self.config.schema_filename(id).as_path().exists())
    }

    fn add_schema(&mut self, schema: &Schema) -> Result<bool, Self::Error> {
        let filename = self.config.schema_filename(&schema.schema_id());
        let exists = filename.as_path().exists();
        schema.write_file(filename)?;
        Ok(exists)
    }

    fn remove_schema(&mut self, id: &SchemaId) -> Result<bool, Self::Error> {
        let filename = self.config.schema_filename(id);
        let existed = filename.as_path().exists();
        fs::remove_file(filename)?;
        Ok(existed)
    }

    fn contract_ids(&self) -> Result<Vec<ContractId>, Self::Error> {
        self.config
            .genesis_names()?
            .into_iter()
            .try_fold(vec![], |mut list, name| {
                let name = name.replace(".rgb", "");
                list.push(ContractId::from_bech32_str(&name)?);
                Ok(list)
            })
    }

    #[inline]
    fn genesis(&self, id: &ContractId) -> Result<Genesis, Self::Error> {
        Ok(Genesis::read_file(self.config.genesis_filename(id))?)
    }

    #[inline]
    fn has_genesis(&self, id: &ContractId) -> Result<bool, Self::Error> {
        Ok(self.config.genesis_filename(id).as_path().exists())
    }

    fn add_genesis(&mut self, genesis: &Genesis) -> Result<bool, Self::Error> {
        let filename = self.config.genesis_filename(&genesis.contract_id());
        let exists = filename.as_path().exists();
        genesis.write_file(filename)?;
        Ok(exists)
    }

    #[inline]
    fn remove_genesis(&mut self, id: &ContractId) -> Result<bool, Self::Error> {
        let filename = self.config.genesis_filename(id);
        let existed = filename.as_path().exists();
        fs::remove_file(filename)?;
        Ok(existed)
    }

    fn anchor(&self, id: &AnchorId) -> Result<Anchor<MerkleBlock>, Self::Error> {
        Ok(Anchor::read_file(self.config.anchor_filename(id))?)
    }

    fn has_anchor(&self, id: &AnchorId) -> Result<bool, Self::Error> {
        Ok(self.config.anchor_filename(id).as_path().exists())
    }

    fn add_anchor(&mut self, anchor: &Anchor<MerkleBlock>) -> Result<bool, Self::Error> {
        let filename = self.config.anchor_filename(&anchor.anchor_id());
        let exists = filename.as_path().exists();
        anchor.write_file(filename)?;
        Ok(exists)
    }

    fn remove_anchor(&mut self, id: &AnchorId) -> Result<bool, Self::Error> {
        let filename = self.config.anchor_filename(id);
        let existed = filename.as_path().exists();
        fs::remove_file(filename)?;
        Ok(existed)
    }

    fn transition(&self, id: &NodeId) -> Result<Transition, Self::Error> {
        Ok(Transition::read_file(self.config.transition_filename(id))?)
    }

    fn has_transition(&self, id: &NodeId) -> Result<bool, Self::Error> {
        Ok(self.config.transition_filename(id).as_path().exists())
    }

    fn add_transition(&mut self, transition: &Transition) -> Result<bool, Self::Error> {
        let filename = self.config.transition_filename(&transition.node_id());
        let exists = filename.as_path().exists();
        transition.write_file(filename)?;
        Ok(exists)
    }

    fn remove_transition(&mut self, id: &NodeId) -> Result<bool, Self::Error> {
        let filename = self.config.transition_filename(id);
        let existed = filename.as_path().exists();
        fs::remove_file(filename)?;
        Ok(existed)
    }

    fn extension(&self, id: &NodeId) -> Result<Extension, Self::Error> {
        Ok(Extension::read_file(self.config.extension_filename(id))?)
    }

    fn has_extension(&self, id: &NodeId) -> Result<bool, Self::Error> {
        Ok(self.config.extension_filename(id).as_path().exists())
    }

    fn add_extension(&mut self, extension: &Extension) -> Result<bool, Self::Error> {
        let filename = self.config.extension_filename(&extension.node_id());
        let exists = filename.as_path().exists();
        extension.write_file(filename)?;
        Ok(exists)
    }

    fn remove_extension(&mut self, id: &NodeId) -> Result<bool, Self::Error> {
        let filename = self.config.extension_filename(id);
        let existed = filename.as_path().exists();
        fs::remove_file(filename)?;
        Ok(existed)
    }
}
